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
import AppKit

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // 如果为 nil 则自动选择
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    
    private var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    private var logStreamerCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var lastDetectedSampleRate: Float64?
    
    var timerActive = false
    var timerCalls = 0
    
    private var heartbeatCancellable: AnyCancellable?
    
    /// 采样率是否刚刚发生显著变化
    private var sampleRateJustChanged: Bool = false
    private var lastSampleRateChangeDate: Date = Date()
    
    /// 当前采样率稳定的时间（用于预缓冲保护）
    private var sampleRateStableSince: Date = Date()
    
    // 跟踪潜在的降级（用于防抖/延迟逻辑）
    private var pendingDowngradeStat: CMPlayerStats?
    private var pendingDowngradeDetectedAt: Date?
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
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
        
        if let persistentID = userInfo["PersistentID"] as? Int {
            let trackID = String(persistentID)
            self.checkTrackChange(newTrackID: trackID)
        } else if let persistentIDStr = userInfo["PersistentID"] as? String {
             self.checkTrackChange(newTrackID: persistentIDStr)
        }
    }
    
    private func checkTrackChange(newTrackID: String) {
        if newTrackID != self.lastKnownTrackID {
            print("Track Changed (Notify): \(newTrackID)")
            self.handleTrackIDChange(newID: newTrackID)
        }
    }
    
    private func handleTrackIDChange(newID: String) {
        self.lastKnownTrackID = newID
        self.lastTrackChangeDate = Date()
        
        // 如果有为下一曲预留的采样率，现在应用它
        if let pending = self.pendingNextTrackStat {
            print("Applying pending pre-buffered rate: \(pending.sampleRate)")
            self.processQueue.async {
                self.applySampleRate(stat: pending, recursion: false)
                self.pendingNextTrackStat = nil
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
    
    func renewTimer() {
        if timerCancellable != nil { return }
        timerCancellable = Timer
            .publish(every: 2, on: .main, in: .default)
            .autoconnect()
            .sink { _ in
                if self.timerCalls == 5 {
                    self.timerCalls = 0
                    self.timerCancellable?.cancel()
                    self.timerCancellable = nil
                }
                else {
                    self.timerCalls += 1
                    self.processQueue.async {
                        self.switchLatestSampleRate()
                    }
                }
            }
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate)
    }
    

    
    func getAllStats() -> [CMPlayerStats] {
        if #available(macOS 15.0, *) {
            // macOS 15+ 无法直接通过 OSLogStore 获取系统日志
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
    private var lastTrackChangeDate: Date = Date.distantPast
    private var isMusicPlaying: Bool = false
    private var pendingNextTrackStat: CMPlayerStats?
    
    /// 根据检测到的音频流切换输出采样率
    /// 逻辑：
    /// - 从 CoreAudio/CoreMedia 日志检测采样率变化
    /// - 显着变化时允许任何调整（升级或降级）
    /// - 稳定播放期间防止误触发降级，允许显著升级 (≥5%)
    func switchLatestSampleRate(recursion: Bool = false) {
        var allStats = self.getAllStats()
        
        // Prioritize LogStreamer data
        if let streamedStat = LogStreamer.shared.latestStats {
             let timeDiff = abs(Date().timeIntervalSince(streamedStat.date))
             if timeDiff < 30.0 {
                 allStats.insert(streamedStat, at: 0)
             }
        }
        
        guard let first = allStats.first else { return }
        
        // Apple Music 预缓冲保护
        if self.isMusicPlaying, let _ = self.lastKnownTrackID {
            if let currentSR = self.currentSampleRate {
                let detectedHz = first.sampleRate
                let currentHz = currentSR * 1000
                
                if abs(detectedHz - currentHz) > 100 {
                    // 若切歌时间极短（2.5秒内），认为该变化是针对当前曲目的
                    let timeSinceTrackChange = Date().timeIntervalSince(self.lastTrackChangeDate)
                    if timeSinceTrackChange < 2.5 {
                         print("Allowing change for new track (changed \(String(format: "%.1fs", timeSinceTrackChange)) ago)")
                    }
                    else {
                        // 疑似中途变化：可能是预缓冲。由于无法使用自动化权限验证，我们假设它是预缓冲并暂时挂起。
                        print("Suspicious rate change detected: \(detectedHz)Hz (current: \(currentHz)Hz). Assuming Pre-buffer. Holding.")
                        self.pendingNextTrackStat = first
                        return
                    }
                }
            }
        }
        
        self.applySampleRate(stat: first, recursion: recursion)
    }
    
    private func applySampleRate(stat: CMPlayerStats, recursion: Bool) {
        let first = stat
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        guard let supported = defaultDevice?.nominalSampleRates else { return }
            
        let sampleRate = Float64(first.sampleRate)
        let bitDepth = Int32(first.bitDepth)
            
            if let prevSampleRate = currentSampleRate {
                let prevSampleRateHz = prevSampleRate * 1000
                
                // 1. 稳定性检查：采样率变化小于 1kHz 时视为未变
                if abs(prevSampleRateHz - sampleRate) < 1000 {
                    if sampleRateJustChanged && Date().timeIntervalSince(lastSampleRateChangeDate) > 3.0 {
                        sampleRateJustChanged = false
                    }
                    if Date().timeIntervalSince(sampleRateStableSince) >= 0.5 {
                        sampleRateStableSince = Date()
                    }
                    return
                }
                
                // 2. 降级保护
                if sampleRate < prevSampleRateHz {
                    if first.priority >= 5 {
                        pendingDowngradeStat = nil
                        pendingDowngradeDetectedAt = nil
                    } 
                    else {
                        // 低优先级降级需要进行防抖验证（1.0s），防止 Hi-Res 播放期间的虚假事件
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
                
                // 3. 升级保护：忽略小于 5% 的微调
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
            
            // 48kHz 采样率检测的重试机制
            if sampleRate == 48000 && !recursion {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            let formats = self.getFormats(bestStat: first, device: defaultDevice!)!
            
            let nearest = supported.min(by: {
                abs($0 - sampleRate) < abs($1 - sampleRate)
            })
            
            let nearestBitDepth = formats.min(by: {
                abs(Int32($0.mBitsPerChannel) - bitDepth) < abs(Int32($1.mBitsPerChannel) - bitDepth)
            })
            
            let nearestFormat = formats.filter({
                $0.mSampleRate == nearest && $0.mBitsPerChannel == nearestBitDepth?.mBitsPerChannel
            })
            
            if let suitableFormat = nearestFormat.first {
                
                if enableBitDepthDetection {
                    self.setFormats(device: defaultDevice, format: suitableFormat)
                }
                else if suitableFormat.mSampleRate != previousSampleRate {
                    defaultDevice?.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                
                self.updateSampleRate(suitableFormat.mSampleRate)
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
    
    func updateSampleRate(_ sampleRate: Float64) {
        self.previousSampleRate = sampleRate
        DispatchQueue.main.async {
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            
            let delegate = AppDelegate.instance
            delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
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

/// LogStreamer 监控系统日志以检测采样率和位深度
/// 适用于所有音频播放器（Apple Music, Spotify, 浏览器等）
class LogStreamer: ObservableObject {
    static let shared = LogStreamer()
    private var process: Process?
    private var pipe: Pipe?
    
    @Published var latestStats: CMPlayerStats?
    
    private init() {}
    
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
                // 遇到 EOF，停止处理器以防止死循环 (100% CPU)
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
            // 静默失败 - AppleScript 后备方案将处理检测
        }
    }
    
    func stop() {
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        pipe = nil
    }
    
    /// 解析日志输出以提取采样率和位深度信息
    /// 优先级：CoreAudio (5) > CoreMedia (2)
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            // CoreAudio 解析 - 最可靠的来源
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
                    self.updateStats(stat)
                    continue
                }
            }

            // CoreMedia 解析 - 备选方案
            if line.contains("Creating AudioQueue") && line.contains("sampleRate:") {
                if let subSampleRate = line.firstSubstring(between: "sampleRate:", and: .end) {
                    let str = String(subSampleRate)
                    let scanners = Scanner(string: str)
                    if let sr = scanners.scanDouble() {
                        var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                        stat.processName = self.extractProcessName(from: line)
                        self.updateStats(stat)
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
                        self.updateStats(stat)
                        continue
                    }
                }
            }
        }
    }
    
    private func updateStats(_ stat: CMPlayerStats) {
        DispatchQueue.main.async {
            self.latestStats = stat
        }
    }
    
    private func extractProcessName(from line: String) -> String? {
        // 日志格式通常为: "Date Time Hostname ProcessName[PID]: Message..."
        // 或 "Date Time Df ProcessName[PID:TID] ..."
        
        // 简单启发式：查找 "... Music[..." 或 "... Spotify[..."
        if let range = line.range(of: "[") {
            let preamble = line[..<range.lowerBound]
            if let lastWord = preamble.components(separatedBy: .whitespaces).last {
                return lastWord
            }
        }
        return nil
    }
}
                              
