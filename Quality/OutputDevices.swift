//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice?
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]() {
        didSet {
            self.syncSelectedOutputDevice()
        }
    }
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    
    private var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var logStreamerCancellable: AnyCancellable?
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var lastDetectedSampleRate: Float64?
    
    private var heartbeatCancellable: AnyCancellable?

    private func debugLog(_ message: String) {
        guard Defaults.shared.userPreferDebugMenu else { return }
        print("[LosslessSwitcher][Debug] \(message)")
    }
    
    private var sampleRateJustChanged: Bool = false
    private var lastSampleRateChangeDate: Date = Date()
    
    private var sampleRateStableSince: Date = Date()
    
    private var pendingDowngradeStat: CMPlayerStats?
    private var pendingDowngradeDetectedAt: Date?

    private var lastProcessedStatDate: Date?
    private var lastProcessedGeneration: UInt64 = 0
    
    private let musicSessionWindow: TimeInterval = 15.0
    private let musicDowngradeConfirmWindow: TimeInterval = 12.0
    private let musicHighRateSilenceWindow: TimeInterval = 8.0
    private var lastMusicLogAt: Date?
    private var lastMusicHighRateAt: Date?
    private var pendingMusicDowngradeStat: CMPlayerStats?
    private var pendingMusicDowngradeDetectedAt: Date?
    private var pendingMusicDowngradeLastSeen: Date?

    private func syncSelectedOutputDevice() {
        if let selected = selectedOutputDevice {
            let stillExists = outputDevices.contains(where: { $0.uid == selected.uid })
            if !stillExists {
                selectedOutputDevice = nil
                Defaults.shared.selectedDeviceUID = nil
            }
            return
        }

        if let savedUID = Defaults.shared.selectedDeviceUID,
           let savedDevice = outputDevices.first(where: { $0.uid == savedUID }) {
            selectedOutputDevice = savedDevice
        }
    }

    private func updateBitDepthIfNeeded(_ bitDepth: Int?) {
        guard let bitDepth else { return }
        if self.currentBitDepth == bitDepth {
            return
        }
        DispatchQueue.main.async {
            self.currentBitDepth = bitDepth
        }
    }
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        if let savedUID = Defaults.shared.selectedDeviceUID,
           let savedDevice = self.outputDevices.first(where: { $0.uid == savedUID }) {
            self.selectedOutputDevice = savedDevice
        } else {
            self.selectedOutputDevice = nil
        }
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = selectedOutputDevice.publisher.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })
        
        if #available(macOS 15.0, *) {
            LogStreamer.shared.start()
        }
        
        logStreamerCancellable = LogStreamer.shared.$latestStats
            .dropFirst()
            .receive(on: processQueue)
            .sink { [weak self] _ in
                self?.switchLatestSampleRate()
            }
        
        self.startHeartbeat()
        self.startMusicAppMonitoring()
    }
    
    func startMusicAppMonitoring() {
        let dnc = DistributedNotificationCenter.default()
        let handler: (Notification) -> Void = { [weak self] notification in
            guard let self = self else { return }
            self.handleMusicNotification(notification)
        }
        
        dnc.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: nil, using: handler)
        dnc.addObserver(forName: NSNotification.Name("com.apple.iTunes.playerInfo"), object: nil, queue: nil, using: handler)
    }
    
    private func handleMusicNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        if let state = userInfo["Player State"] as? String {
            let wasPlaying = self.isMusicPlaying
            self.isMusicPlaying = (state == "Playing")
            
            if !wasPlaying && self.isMusicPlaying {
                print("Playback Resumed: Resetting track change timer")
                self.lastTrackChangeDate = Date()
            }
        }
        
        var trackID: String?
        if let persistentID = userInfo["PersistentID"] as? Int {
            trackID = String(persistentID)
            self.checkTrackChange(newTrackID: trackID ?? "")
        } else if let persistentIDStr = userInfo["PersistentID"] as? String {
            trackID = persistentIDStr
            self.checkTrackChange(newTrackID: persistentIDStr)
        }

        let trackName = (userInfo["Name"] as? String) ?? (userInfo["Title"] as? String)
        if let trackName = trackName, !trackName.isEmpty {
            self.checkTrackNameChange(newTrackName: trackName)
        }
        LogStreamer.shared.updateCurrentTrackInfo(trackID: trackID, trackName: trackName)
    }
    
    private func checkTrackChange(newTrackID: String) {
        if newTrackID != self.lastKnownTrackID {
            print("Track Changed (Notify): \(newTrackID)")
            self.handleTrackIDChange(newID: newTrackID)
        }
    }

    private func checkTrackNameChange(newTrackName: String) {
        if newTrackName != self.lastKnownTrackName {
            print("Track Changed (Name): \(newTrackName)")
            self.handleTrackNameChange(newName: newTrackName)
        }
    }
    
    private func handleTrackIDChange(newID: String) {
        self.lastKnownTrackID = newID
        self.lastTrackChangeDate = Date()
        self.pendingMusicDowngradeStat = nil
        self.pendingMusicDowngradeDetectedAt = nil
        self.pendingMusicDowngradeLastSeen = nil
        
        if let pending = self.pendingNextTrackStat {
            print("Applying pending pre-buffered rate: \(pending.sampleRate)")
            self.processQueue.async {
                self.applySampleRate(stat: pending, recursion: false, bypassDowngradeProtection: true)
                self.pendingNextTrackStat = nil
                self.pendingNextTrackStatLastSeen = nil
            }
        }
    }

    private func handleTrackNameChange(newName: String) {
        self.lastKnownTrackName = newName
        self.lastTrackChangeDate = Date()
        self.pendingMusicDowngradeStat = nil
        self.pendingMusicDowngradeDetectedAt = nil
        self.pendingMusicDowngradeLastSeen = nil

        if let pending = self.pendingNextTrackStat {
            print("Applying pending pre-buffered rate (name): \(pending.sampleRate)")
            self.processQueue.async {
                self.applySampleRate(stat: pending, recursion: false, bypassDowngradeProtection: true)
                self.pendingNextTrackStat = nil
                self.pendingNextTrackStatLastSeen = nil
            }
        }
    }
    
    deinit {
        LogStreamer.shared.stop()
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        logStreamerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        heartbeatCancellable?.cancel()
    }
    
    func startHeartbeat() {
        heartbeatCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.processQueue.async {
                    self?.switchLatestSampleRate()
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        var bitDepth: Int? = nil
        if let streams = defaultDevice?.streams(scope: .output),
           let format = streams.first?.physicalFormat {
            bitDepth = Int(format.mBitsPerChannel)
        }
        self.updateSampleRate(sampleRate, bitDepth: bitDepth)
    }
    
    func getAllStats() -> [CMPlayerStats] {
        if #available(macOS 15.0, *) {
            return []
        }
        
        var stats = [CMPlayerStats]()
        
        do {
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
            stats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
            
            let musicLogs = try Console.getRecentEntries(type: .music)
            stats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
            
            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            stats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
        } catch {
            print("OSLogStore fetch error: \(error)")
        }
        
        return stats.sorted(by: { $0.priority > $1.priority })
    }

    private var lastKnownTrackID: String?
    private var lastKnownTrackName: String?
    private var lastTrackChangeDate: Date = Date.distantPast
    private var isMusicPlaying: Bool = false
    private var pendingNextTrackStat: CMPlayerStats?
    private var pendingNextTrackStatLastSeen: Date?
    
    func switchLatestSampleRate(recursion: Bool = false) {
            if let pending = self.pendingNextTrackStat,
               let lastSeen = self.pendingNextTrackStatLastSeen {
                let timeSinceLastSeen = abs(Date().timeIntervalSince(lastSeen))
                if timeSinceLastSeen > 10.0 {
                    let isAppleMusicSafetyContext = self.isMusicPlaying || isMusicProcessName(pending.processName)
                    if isAppleMusicSafetyContext, (self.lastKnownTrackID != nil || self.lastKnownTrackName != nil) {
                        return
                    }
                    print("Applying pre-buffered rate: \(pending.sampleRate) (no pre-buffer log for \(String(format: "%.1fs", timeSinceLastSeen)))")
                    self.applySampleRate(stat: pending, recursion: false, bypassDowngradeProtection: true)
                    self.pendingNextTrackStat = nil
                    self.pendingNextTrackStatLastSeen = nil
                    return
                }
            }
        
        var allStats = self.getAllStats()
        
        let currentGen = LogStreamer.shared.statGeneration
        if let streamedStat = LogStreamer.shared.latestStats {
             let timeDiff = abs(Date().timeIntervalSince(streamedStat.date))
             if timeDiff < 120.0 {
                 allStats.insert(streamedStat, at: 0)
             }
        }
        
        guard let first = allStats.first else { return }

        let isNewStat: Bool
        if currentGen != self.lastProcessedGeneration {
            self.lastProcessedGeneration = currentGen
            isNewStat = true
        } else if let lastDate = self.lastProcessedStatDate {
            isNewStat = abs(first.date.timeIntervalSince(lastDate)) > 0.01 ||
                        abs(first.sampleRate - (lastDetectedSampleRate ?? 0)) > 1
        } else {
            isNewStat = true
        }
        self.lastProcessedStatDate = first.date
        self.lastDetectedSampleRate = first.sampleRate
        let now = Date()
        let isMusicStat = isMusicProcessName(first.processName)
        if isMusicStat, isNewStat {
            lastMusicLogAt = now
            if let currentSR = currentSampleRate {
                let currentHz = currentSR * 1000
                if abs(first.sampleRate - currentHz) < 100 {
                    lastMusicHighRateAt = now
                }
            }
        }
        let isMusicSessionActive = lastMusicLogAt.map { now.timeIntervalSince($0) < musicSessionWindow } ?? false
        // Music 降级确认窗口：防止 Hi-Res 播放中途瞬态低码率日志误触降级
        // 但如果刚切歌（8s 内），降级是合法的新曲目码率，跳过确认直接放行到后续预缓冲保护
        let recentTrackSwitch = now.timeIntervalSince(self.lastTrackChangeDate) < 8.0
        if isMusicStat, isMusicSessionActive, !recentTrackSwitch, let currentSR = currentSampleRate {
            let currentHz = currentSR * 1000
            if first.sampleRate < currentHz - 100 {
                let isNewPending = pendingMusicDowngradeStat == nil ||
                    abs((pendingMusicDowngradeStat?.sampleRate ?? 0) - first.sampleRate) > 1

                if isNewPending {
                    pendingMusicDowngradeStat = first
                    pendingMusicDowngradeDetectedAt = now
                    pendingMusicDowngradeLastSeen = now
                    return
                }

                if isNewStat {
                    pendingMusicDowngradeLastSeen = now
                }

                if let detectedAt = pendingMusicDowngradeDetectedAt,
                   now.timeIntervalSince(detectedAt) >= musicDowngradeConfirmWindow {
                    let highRateSilent = lastMusicHighRateAt.map { now.timeIntervalSince($0) >= musicHighRateSilenceWindow } ?? true
                    if !highRateSilent {
                        return
                    }
                    pendingMusicDowngradeStat = nil
                    pendingMusicDowngradeDetectedAt = nil
                    pendingMusicDowngradeLastSeen = nil
                    self.applySampleRate(stat: first, recursion: false, bypassDowngradeProtection: true)
                    return
                } else {
                    return
                }
            } else {
                pendingMusicDowngradeStat = nil
                pendingMusicDowngradeDetectedAt = nil
                pendingMusicDowngradeLastSeen = nil
            }
        }
        if recentTrackSwitch {
            // 刚切歌时清除之前的降级挂起状态，避免残留影响新曲目
            pendingMusicDowngradeStat = nil
            pendingMusicDowngradeDetectedAt = nil
            pendingMusicDowngradeLastSeen = nil
        }
        
        let isAppleMusicContext = self.isMusicPlaying || isMusicProcessName(first.processName)
        if isAppleMusicContext, (self.lastKnownTrackID != nil || self.lastKnownTrackName != nil) {
            if let currentSR = self.currentSampleRate {
                let detectedHz = first.sampleRate
                let currentHz = currentSR * 1000
                
                if abs(detectedHz - currentHz) > 100 {
                    let timeSinceTrackChange = Date().timeIntervalSince(self.lastTrackChangeDate)
                    if timeSinceTrackChange < 8.0 {
                        // 在新曲目窗口内，如果已经为当前曲目应用过采样率变化，
                        // 且新检测到的是降级，则视为下一首的预缓冲而非当前曲目的变化
                        let isDowngrade = detectedHz < currentHz - 100
                        let alreadyAppliedForThisTrack = self.lastSampleRateChangeDate > self.lastTrackChangeDate
                        
                        if isDowngrade && alreadyAppliedForThisTrack {
                            let isNewLog = self.pendingNextTrackStatLastSeen == nil ||
                                           first.date > self.pendingNextTrackStatLastSeen!
                            if isNewLog {
                                print("Suspicious rate change detected: \(detectedHz)Hz (current: \(currentHz)Hz). Assuming Pre-buffer (post-switch downgrade in new-track window). Holding.")
                                self.pendingNextTrackStat = first
                                self.pendingNextTrackStatLastSeen = first.date
                            }
                            return
                        }
                        
                        print("Allowing change for new track (changed \(String(format: "%.1fs", timeSinceTrackChange)) ago)")
                    }
                    else {
                        let isNewLog = self.pendingNextTrackStatLastSeen == nil || 
                                       first.date > self.pendingNextTrackStatLastSeen!
                        
                        if isNewLog {
                            print("Suspicious rate change detected: \(detectedHz)Hz (current: \(currentHz)Hz). Assuming Pre-buffer. Holding.")
                            self.pendingNextTrackStat = first
                            self.pendingNextTrackStatLastSeen = first.date
                        }
                        return
                    }
                }
            }
        }
        
        self.applySampleRate(stat: first, recursion: recursion)
    }

    private func isMusicProcessName(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name == "music" || name == "itunes"
    }
    
    private func applySampleRate(stat: CMPlayerStats, recursion: Bool, bypassDowngradeProtection: Bool = false) {
        let first = stat
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        guard let supported = defaultDevice?.nominalSampleRates else { return }
            
        let sampleRate = Float64(first.sampleRate)
        let bitDepth = Int32(first.bitDepth)
            if let prevSampleRate = currentSampleRate {
                let prevSampleRateHz = prevSampleRate * 1000
                
                // 1. 稳定性检查
                if abs(prevSampleRateHz - sampleRate) < 1000 {
                    self.updateBitDepthIfNeeded(Int(bitDepth))
                    if sampleRateJustChanged && Date().timeIntervalSince(lastSampleRateChangeDate) > 3.0 {
                        sampleRateJustChanged = false
                    }
                    return
                }
                
                // 2. 降级保护
                if sampleRate < prevSampleRateHz {
                    if bypassDowngradeProtection {
                        pendingDowngradeStat = nil
                        pendingDowngradeDetectedAt = nil
                    } else if first.priority >= 5 {
                        let stableDuration = Date().timeIntervalSince(sampleRateStableSince)
                        let recentTrackChange = Date().timeIntervalSince(lastTrackChangeDate) < 2.0
                        
                        if stableDuration <= 10.0 || recentTrackChange {
                            pendingDowngradeStat = nil
                            pendingDowngradeDetectedAt = nil
                        } else {
                            if let pending = pendingDowngradeStat,
                               abs(Double(pending.sampleRate) - sampleRate) < 1.0 {
                                if let firstDetected = pendingDowngradeDetectedAt,
                                   Date().timeIntervalSince(firstDetected) > 3.0 {
                                    pendingDowngradeStat = nil
                                    pendingDowngradeDetectedAt = nil
                                } else {
                                    return
                                }
                            } else {
                                pendingDowngradeStat = first
                                pendingDowngradeDetectedAt = Date()
                                processQueue.asyncAfter(deadline: .now() + 3.2) {
                                    self.switchLatestSampleRate()
                                }
                                return
                            }
                        }
                    } 
                    else {
                        if let pending = pendingDowngradeStat,
                           abs(Double(pending.sampleRate) - sampleRate) < 1.0 {
                            
                            if let firstDetected = pendingDowngradeDetectedAt,
                               Date().timeIntervalSince(firstDetected) > 1.0 {
                                pendingDowngradeStat = nil
                                pendingDowngradeDetectedAt = nil
                            } else {
                                return
                            }
                        } else {
                            pendingDowngradeStat = first
                            pendingDowngradeDetectedAt = Date()
                            
                            processQueue.asyncAfter(deadline: .now() + 1.2) {
                                self.switchLatestSampleRate()
                            }
                            return
                        }
                    }
                } else {
                     pendingDowngradeStat = nil
                     pendingDowngradeDetectedAt = nil
                }
                
                // 3. 升级保护
                let upgradeRatio = sampleRate / prevSampleRateHz
                if upgradeRatio < 1.05 && sampleRate >= prevSampleRateHz {
                     return
                }
            } else {
                pendingDowngradeStat = nil
                pendingDowngradeDetectedAt = nil
            }
            
            sampleRateJustChanged = true
            lastSampleRateChangeDate = Date()
            sampleRateStableSince = Date()
            
            if sampleRate == 48000 && !recursion {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            let formats = self.getFormats(bestStat: first, device: defaultDevice!)!
            
            let nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })

            let matchingRateFormats = formats.filter({ $0.mSampleRate == nearest })
            let nearestBitDepthFormat = matchingRateFormats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })

            if let suitableFormat = nearestBitDepthFormat ?? matchingRateFormats.first {
                let prevRate = currentSampleRate
                let prevBit = currentBitDepth
                let newRate = suitableFormat.mSampleRate / 1000.0
                let newBit = Int(suitableFormat.mBitsPerChannel)
                let rateChanged = prevRate == nil || abs((prevRate ?? 0) * 1000.0 - suitableFormat.mSampleRate) >= 1000
                let bitChanged = enableBitDepthDetection && (prevBit == nil || prevBit != newBit)

                if rateChanged || bitChanged {
                    let prevRateText = prevRate.map { String(format: "%.1f", $0) } ?? "-"
                    let prevBitText = prevBit.map { "\($0)bit" } ?? "-"
                    let source = first.processName?.isEmpty == false ? first.processName! : first.sourceLabel
                    let track = first.trackName?.isEmpty == false ? first.trackName! : "-"
                    debugLog("Switch \(prevRateText)kHz/\(prevBitText) -> \(String(format: "%.1f", newRate))kHz/\(newBit)bit src=\(source) pri=\(first.priority) track=\(track)")
                }
                
                if enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                }
                else if suitableFormat.mSampleRate != previousSampleRate {
                    defaultDevice?.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                
                self.updateSampleRate(suitableFormat.mSampleRate, bitDepth: Int(bitDepth))
            }
    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate

            if let bitDepth = bitDepth {
                self.currentBitDepth = bitDepth
            }
        }
        self.runUserScript(sampleRate)
    }
    
    func runUserScript(_ sampleRate: Float64) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                let arguments = [
                    argumentSampleRate
                ]
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
}

import Sweep

class LogStreamer: ObservableObject {
    static let shared = LogStreamer()
    private var process: Process?
    private var pipe: Pipe?
    
    @Published var latestStats: CMPlayerStats?
    @Published var recentTracks: [DebugTrackEntry] = []
    private(set) var statGeneration: UInt64 = 0
    private let debugHistoryLimit = 3
    private var currentTrackID: String?
    private var currentTrackName: String?
    private var currentTrackSignature: String?
    
    private init() {}

#if DEBUG
    func resetDebugStateForTests() {
        latestStats = nil
        recentTracks = []
        statGeneration = 0
        currentTrackID = nil
        currentTrackName = nil
        currentTrackSignature = nil
    }
#endif

    func updateCurrentTrackInfo(trackID: String?, trackName: String?) {
        DispatchQueue.main.async {
            let normalizedID = trackID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = trackName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let now = Date()

            if let id = normalizedID, !id.isEmpty, id != self.currentTrackID {
                self.currentTrackID = id
                if let name = normalizedName, !name.isEmpty {
                    self.currentTrackName = name
                }
                let nameForEntry = self.currentTrackName ?? normalizedName ?? "Unknown"
                let key = self.makeTrackKey(id: id, name: self.currentTrackName) ?? id
                self.currentTrackSignature = key
                self.upsertTrackEntry(
                    key: key,
                    trackName: nameForEntry,
                    processName: "Music",
                    sampleRate: nil,
                    bitDepth: nil,
                    date: now,
                    makeCurrent: true
                )
                return
            }

            guard let name = normalizedName, !name.isEmpty else { return }
            if name == self.currentTrackName { return }

            let wasNameEmpty = self.currentTrackName == nil || self.currentTrackName?.isEmpty == true
            self.currentTrackName = name
            let newKey = self.makeTrackKey(id: self.currentTrackID, name: name) ?? name

            if wasNameEmpty, let oldKey = self.currentTrackSignature, oldKey != newKey {
                self.currentTrackSignature = newKey
                self.replaceTrackEntryKey(oldKey: oldKey, newKey: newKey, trackName: name, date: now)
                return
            }

            if self.currentTrackSignature != newKey {
                self.currentTrackSignature = newKey
                self.upsertTrackEntry(
                    key: newKey,
                    trackName: name,
                    processName: "Music",
                    sampleRate: nil,
                    bitDepth: nil,
                    date: now,
                    makeCurrent: true
                )
            } else if let key = self.currentTrackSignature {
                if !self.updateTrackName(key: key, trackName: name) {
                    self.upsertTrackEntry(
                        key: key,
                        trackName: name,
                        processName: "Music",
                        sampleRate: nil,
                        bitDepth: nil,
                        date: now,
                        makeCurrent: true
                    )
                }
            }
        }
    }
    
    func start() {
        stop()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--predicate",
            "(subsystem == \"com.apple.coreaudio\" OR subsystem == \"com.apple.coremedia\")",
            "--style", "compact"
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        self.pipe = pipe
        self.process = process
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            if let string = String(data: data, encoding: .utf8) {
                self?.processOutput(string)
            }
        }
        
        do {
            try process.run()
        } catch {
        }
    }
    
    func stop() {
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        pipe = nil
    }
    
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            if line.contains("ACAppleLosslessDecoder.cpp") && line.contains("Input format:") {
                var sampleRate: Double?
                var bitDepth: Int?

                if let subSampleRate = line.firstSubstring(between: "ch, ", and: " Hz") {
                    let strSampleRate = String(subSampleRate).trimmingCharacters(in: .whitespacesAndNewlines)
                    sampleRate = Double(strSampleRate)
                }
                
                if let subBitDepth = line.firstSubstring(between: "from ", and: "-bit source") {
                    let strBitDepth = String(subBitDepth).trimmingCharacters(in: .whitespacesAndNewlines)
                    bitDepth = Int(strBitDepth)
                }
                
                if let sr = sampleRate, let bd = bitDepth {
                    var stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: Date(), priority: 5)
                    stat.processName = self.extractProcessName(from: line)
                    if self.isMusicProcess(stat.processName) {
                        stat.trackName = self.currentTrackName
                    }
                    self.appendDebugStat(stat)
                    continue
                }
            }

            if line.contains("fpfs_ReportAudioPlaybackThroughFigLog") {
                var sampleRate: Double?
                var bitDepth: Int?

                if let subSampleRate = line.firstSubstring(between: "[SampleRate ", and: "]") {
                    let strSampleRate = String(subSampleRate).trimmingCharacters(in: .whitespacesAndNewlines)
                    sampleRate = Double(strSampleRate)
                }

                if let subBitDepth = line.firstSubstring(between: "[BitDepth ", and: "]") {
                    let strBitDepth = String(subBitDepth).trimmingCharacters(in: .whitespacesAndNewlines)
                    bitDepth = Int(strBitDepth)
                }

                if let sr = sampleRate {
                    var stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth ?? 24, date: Date(), priority: 2)
                    stat.processName = self.extractProcessName(from: line)
                    if self.isMusicProcess(stat.processName) {
                        stat.trackName = self.currentTrackName
                    }
                    self.appendDebugStat(stat)
                    continue
                }
            }

            if line.contains("Creating AudioQueue") && line.contains("sampleRate:") {
                if let subSampleRate = line.firstSubstring(between: "sampleRate:", and: .end) {
                    let str = String(subSampleRate)
                    let scanners = Scanner(string: str)
                    if let sr = scanners.scanDouble() {
                        var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                        stat.processName = self.extractProcessName(from: line)
                        if self.isMusicProcess(stat.processName) {
                            stat.trackName = self.currentTrackName
                        }
                        self.appendDebugStat(stat)
                        continue
                    }
                }
                
                let components = line.components(separatedBy: "sampleRate:")
                if components.count > 1 {
                    let after = components[1]
                    let valStr = after.components(separatedBy: CharacterSet(charactersIn: " ,]")).first ?? ""
                    if let sr = Double(valStr) {
                        var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                        stat.processName = self.extractProcessName(from: line)
                        if self.isMusicProcess(stat.processName) {
                            stat.trackName = self.currentTrackName
                        }
                        self.appendDebugStat(stat)
                        continue
                    }
                }
            }
        }
    }
    
    func appendDebugStat(_ stat: CMPlayerStats) {
        DispatchQueue.main.async {
            self.statGeneration += 1
            self.latestStats = stat
            self.updateTrackHistory(with: stat)
        }
    }

    private func extractProcessName(from line: String) -> String? {
        if let range = line.range(of: "[") {
            let preamble = line[..<range.lowerBound]
            if let lastWord = preamble.components(separatedBy: .whitespaces).last {
                return lastWord
            }
        }
        return nil
    }

    private func currentTrackKey() -> String? {
        return currentTrackSignature ?? currentTrackID ?? currentTrackName
    }

    private func makeTrackKey(id: String?, name: String?) -> String? {
        if let id = id, !id.isEmpty, let name = name, !name.isEmpty {
            return "\(id)|\(name)"
        }
        if let id = id, !id.isEmpty {
            return id
        }
        if let name = name, !name.isEmpty {
            return name
        }
        return nil
    }

    private func updateTrackHistory(with stat: CMPlayerStats) {
        guard isMusicProcess(stat.processName) || currentTrackKey() != nil else { return }
        let key = currentTrackKey() ?? stat.trackName ?? "Unknown"
        let name = currentTrackName ?? stat.trackName ?? "Unknown"

        upsertTrackEntry(
            key: key,
            trackName: name,
            processName: stat.processName ?? "Music",
            sampleRate: stat.sampleRate,
            bitDepth: stat.bitDepth,
            date: stat.date,
            makeCurrent: true
        )
    }

    private func upsertTrackEntry(
        key: String,
        trackName: String,
        processName: String?,
        sampleRate: Double?,
        bitDepth: Int?,
        date: Date?,
        makeCurrent: Bool
    ) {
        if let index = recentTracks.firstIndex(where: { $0.id == key }) {
            var entry = recentTracks.remove(at: index)
            entry.trackName = trackName
            entry.processName = processName ?? entry.processName
            if let sampleRate { entry.sampleRate = sampleRate }
            if let bitDepth { entry.bitDepth = bitDepth }
            if let date { entry.date = date }
            if makeCurrent {
                recentTracks.insert(entry, at: 0)
            } else {
                recentTracks.insert(entry, at: index)
            }
        } else {
            let entry = DebugTrackEntry(
                id: key,
                trackName: trackName,
                processName: processName,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                date: date
            )
            if makeCurrent {
                recentTracks.insert(entry, at: 0)
            } else {
                recentTracks.append(entry)
            }
        }

        recentTracks = recentTracks.reduce(into: [DebugTrackEntry]()) { result, entry in
            if !result.contains(where: { $0.id == entry.id }) {
                result.append(entry)
            }
        }

        if recentTracks.count > debugHistoryLimit {
            recentTracks = Array(recentTracks.prefix(debugHistoryLimit))
        }
    }

    private func replaceTrackEntryKey(oldKey: String, newKey: String, trackName: String, date: Date?) {
        if let index = recentTracks.firstIndex(where: { $0.id == oldKey }) {
            let oldEntry = recentTracks.remove(at: index)
            let entry = DebugTrackEntry(
                id: newKey,
                trackName: trackName,
                processName: oldEntry.processName,
                sampleRate: oldEntry.sampleRate,
                bitDepth: oldEntry.bitDepth,
                date: date ?? oldEntry.date
            )
            recentTracks.insert(entry, at: index)
        } else {
            upsertTrackEntry(
                key: newKey,
                trackName: trackName,
                processName: "Music",
                sampleRate: nil,
                bitDepth: nil,
                date: date,
                makeCurrent: true
            )
            return
        }

        recentTracks = recentTracks.reduce(into: [DebugTrackEntry]()) { result, entry in
            if !result.contains(where: { $0.id == entry.id }) {
                result.append(entry)
            }
        }

        if recentTracks.count > debugHistoryLimit {
            recentTracks = Array(recentTracks.prefix(debugHistoryLimit))
        }
    }

    @discardableResult
    private func updateTrackName(key: String, trackName: String) -> Bool {
        if let index = recentTracks.firstIndex(where: { $0.id == key }) {
            recentTracks[index].trackName = trackName
            recentTracks[index].date = Date()
            return true
        }
        return false
    }

    private func isMusicProcess(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name == "music" || name == "itunes"
    }
}
                              
