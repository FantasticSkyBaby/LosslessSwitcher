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
import OSLog

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
    @Published var isFlashing: Bool = false
    
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
        Logger.hardware.debug("\(message, privacy: .public)")
    }
    
    private var sampleRateJustChanged: Bool = false
    private var lastSampleRateChangeDate: Date = Date()
    
    private var sampleRateStableSince: Date = Date()
    
    private var pendingDowngradeStat: CMPlayerStats?
    private var pendingDowngradeDetectedAt: Date?

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
        guard let bitDepth, bitDepth > 0 else { return }
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
        
        let state = userInfo["Player State"] as? String
        let isPlaying = (state == "Playing")
        
        var trackID: String?
        if let persistentID = userInfo["PersistentID"] as? Int {
            trackID = String(persistentID)
        } else if let persistentIDStr = userInfo["PersistentID"] as? String {
            trackID = persistentIDStr
        }

        let trackName = (userInfo["Name"] as? String) ?? (userInfo["Title"] as? String)
        
        // 同步状态到策略引擎
        let trackChanged = SampleRatePolicy.shared.updateMusicState(isPlaying: isPlaying, trackID: trackID, trackName: trackName)
        LogStreamer.shared.updateCurrentTrackInfo(trackID: trackID, trackName: trackName)
        
        // 如果 Track ID 或 Name 变了，立即同步尝试切换（应用预缓冲），保证同步切换码率
        if trackChanged {
            self.processQueue.sync {
                self.switchLatestSampleRate()
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
           let format = streams.first?.physicalFormat,
           format.mBitsPerChannel > 0 {
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
            Logger.hardware.error("OSLogStore fetch error: \(error, privacy: .public)")
        }
        
        return stats.sorted(by: { $0.priority > $1.priority })
    }

    func switchLatestSampleRate(recursion: Bool = false) {
        // 1. 尝试从实时流获取最新状态
        var bestStat = LogStreamer.shared.latestStats
        
        // 2. 如果实时流没有，或者数据太旧，回退到历史查询（OSLogStore）
        if bestStat == nil || abs(bestStat!.date.timeIntervalSinceNow) > 10 {
            let allStats = self.getAllStats()
            if let first = allStats.first {
                bestStat = first
            }
        }
        
        guard let stat = bestStat else { return }
        
        // 3. 使用策略引擎进行决策
        let result = SampleRatePolicy.shared.evaluate(currentHz: self.previousSampleRate ?? 0, latestStat: stat)
        
        if result.shouldApply, let finalStat = result.stat {
            self.applySampleRate(stat: finalStat, recursion: recursion, bypassDowngradeProtection: result.bypassDowngradeProtection)
        }
    }

    private func applySampleRate(stat: CMPlayerStats, recursion: Bool, bypassDowngradeProtection: Bool = false) {
        let first = stat
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        guard let supported = defaultDevice?.nominalSampleRates else { return }
            
        let sampleRate = Float64(first.sampleRate)
        let bitDepth = Int32(first.bitDepth)
            if let prevSampleRateHz = previousSampleRate {
                
                // 1. 稳定性检查
                if abs(prevSampleRateHz - sampleRate) < AppConfig.Switching.stabilityThresholdHz {
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
                        let recentTrackChange = Date().timeIntervalSince(SampleRatePolicy.shared.lastTrackChangeDate) < 3.0
                        
                        if stableDuration <= AppConfig.Switching.stabilityCooldown || recentTrackChange {
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
                                processQueue.asyncAfter(deadline: .now() + AppConfig.Switching.downgradePendingDelayLong) {
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
                            
                            processQueue.asyncAfter(deadline: .now() + AppConfig.Switching.downgradePendingDelayShort) {
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
                if upgradeRatio < AppConfig.Switching.upgradeRatioThreshold && sampleRate >= prevSampleRateHz {
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
    
    func triggerFlash() {
        DispatchQueue.main.async {
            self.isFlashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.isFlashing = false
            }
        }
    }

    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            if self.currentSampleRate != readableSampleRate {
                self.triggerFlash()
            }
            self.currentSampleRate = readableSampleRate

            if let bitDepth = bitDepth, bitDepth > 0 {
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
                              
