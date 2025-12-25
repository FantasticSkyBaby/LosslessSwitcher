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
import MediaRemoteAdapter

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
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
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    var trackAndSample = [MediaTrack : Float64]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    var timerActive = false
    var timerCalls = 0
    
    private var heartbeatCancellable: AnyCancellable?
    
    /// Flag to indicate if the track just changed, allowing any sample rate change (including downgrade)
    private var trackJustChanged: Bool = false
    
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
        
        // Start LogStreamer
        LogStreamer.shared.start()
        
        // Heartbeat to poll for changes if MediaRemote fails
        self.startHeartbeat()
    }
    
    deinit {
        LogStreamer.shared.stop()
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
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
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let descriptor = script.executeAndReturnError(&error)
            
            if let output = descriptor.stringValue {
                if output == "missing value" {
                    return nil
                }
                return Double(output)
            }
            
            // Fallback for numeric types if stringValue fails
            if descriptor.int32Value != 0 {
                return Double(descriptor.int32Value)
            }
            
            // Silent error fallback
            if let error = error {
                 print("[APPLESCRIPT ERROR] - \(error)")
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        // OSLogStore based fetching is broken on macOS 15+ for system logs from this context.
        // We rely on LogStreamer (background process) and AppleScript fallback.
        return []
    }
    
    /// Switches the audio output sample rate based on detected track information
    /// Core logic:
    /// - On track change: Allows any sample rate change (upgrade or downgrade)
    /// - Same track: Prevents spurious downgrades, allows significant upgrades (≥5%)
    /// - Recursion: Used for retry logic when initial detection might be incomplete
    func switchLatestSampleRate(recursion: Bool = false) {
        var allStats = self.getAllStats()
        
        // Fallback to AppleScript if LogStreamer hasn't detected anything yet
        if allStats.isEmpty, let scriptRate = self.getSampleRateFromAppleScript() {
            let rateHz = scriptRate < 384.0 ? scriptRate * 1000.0 : scriptRate
            let stat = CMPlayerStats(sampleRate: rateHz, bitDepth: 24, date: Date(), priority: 0)
            allStats.append(stat)
        }

        // Prioritize LogStreamer data if it's recent (within 10 seconds)
        if let streamedStat = LogStreamer.shared.latestStats {
             let timeDiff = abs(Date().timeIntervalSince(streamedStat.date))
             if timeDiff < 10.0 { 
                 allStats.insert(streamedStat, at: 0)
             }
        }
        
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            let sampleRate = Float64(first.sampleRate)
            let bitDepth = Int32(first.bitDepth)
            
            // Apply protection logic only for the same track with existing sample rate
            if !trackJustChanged && 
               self.currentTrack == self.previousTrack &&
               self.currentTrack != nil,
               let prevSampleRate = currentSampleRate {
                let prevSampleRateHz = prevSampleRate * 1000
                
                // Skip if sample rate is essentially unchanged (<1kHz difference)
                if abs(prevSampleRateHz - sampleRate) < 1000 {
                    return
                }
                
                // Prevent downgrade on same track (protects against spurious 44kHz detections)
                if sampleRate < prevSampleRateHz {
                    return
                }
                
                // Reject minor upgrades (<5%) to prevent jitter
                // Allows: 44→48kHz (9%), 44→96kHz (118%), 44→192kHz (336%)
                // Rejects: 44→45kHz (2%) noise/jitter
                let upgradeRatio = sampleRate / prevSampleRateHz
                if upgradeRatio < 1.05 {
                    return
                }
            }
            
            // Reset the flag after applying logic
            if trackJustChanged {
                trackJustChanged = false
            }
            
            if sampleRate == 48000 {
                processQueue.asyncAfter(deadline: .now() + 1) {
                    self.switchLatestSampleRate(recursion: true)
                }
            }
            
            let formats = self.getFormats(bestStat: first, device: defaultDevice!)!
            
            // https://stackoverflow.com/a/65060134
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
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                }
            } else {
                // Appropriate format not found
            }


        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
            // Recursion fallback: same track check
            if self.currentTrack == self.previousTrack {
                return
            }
        }

    }
    
    func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
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
    
    /// Called when the current track changes
    /// Sets trackJustChanged flag to allow sample rate downgrades on track switch
    func trackDidChange(_ newTrack: TrackInfo) {
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        if self.previousTrack != self.currentTrack {
            self.trackJustChanged = true
            self.renewTimer()
        }
        processQueue.async { [unowned self] in
            self.switchLatestSampleRate()
        }
    }
}

import Sweep

/// LogStreamer monitors system logs to detect audio sample rate and bit depth information
/// from Apple Music and CoreAudio subsystems. This is necessary on macOS 15+ where
/// direct OSLogStore access for system logs is restricted.
/// 
/// The streamer runs a background `log stream` process and parses log entries from:
/// - CoreAudio (ACAppleLosslessDecoder.cpp): Most reliable, includes both sample rate and bit depth
/// - Apple Music (audioCapabilities): Secondary source for high-level audio info
/// - CoreMedia (AudioQueue): Fallback for basic sample rate detection
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
            "(subsystem == \"com.apple.music\" OR subsystem == \"com.apple.coreaudio\" OR subsystem == \"com.apple.coremedia\")",
            "--style", "compact"
        ]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        self.pipe = pipe
        self.process = process
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let string = String(data: data, encoding: .utf8) {
                self?.processOutput(string)
            }
        }
        
        do {
            try process.run()
        } catch {
            // Silently fail - AppleScript fallback will handle detection
        }
    }
    
    func stop() {
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        pipe = nil
    }
    
    /// Parses log output to extract sample rate and bit depth information
    /// Priority levels: CoreAudio (5) > CoreMedia (2) > Music (1)
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            // CoreAudio parsing - Most reliable source
            // Format: "ACAppleLosslessDecoder.cpp ... Input format: 2 ch, 192000 Hz, from 24-bit source"
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
                    let stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: Date(), priority: 5)
                    self.updateStats(stat)
                    continue
                }
            }
            
            // Apple Music parsing - Secondary source
            // Format: "audioCapabilities: ... asbdSampleRate = 48 kHz ... sdBitDepth = 24 bit"
            if line.contains("audioCapabilities:") {
                if let subSampleRate = line.firstSubstring(between: "asbdSampleRate = ", and: " kHz") {
                    if let sr = Double(String(subSampleRate)) {
                        var bitDepth = 16
                        if let subBitDepth = line.firstSubstring(between: "sdBitDepth = ", and: " bit") {
                             if let bd = Int(String(subBitDepth)) {
                                 bitDepth = bd
                             }
                        }
                        
                        let stat = CMPlayerStats(sampleRate: sr * 1000, bitDepth: bitDepth, date: Date(), priority: 1)
                        self.updateStats(stat)
                        continue
                    }
                }
            }
            
            // CoreMedia parsing - Fallback source
            // Format: "Creating AudioQueue ... sampleRate:48000.0"
            if line.contains("Creating AudioQueue") && line.contains("sampleRate:") {
                if let subSampleRate = line.firstSubstring(between: "sampleRate:", and: .end) {
                    let str = String(subSampleRate)
                    let scanners = Scanner(string: str)
                    if let sr = scanners.scanDouble() {
                        let stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                        self.updateStats(stat)
                        continue
                    }
                }
                
                // Fallback parsing
                let components = line.components(separatedBy: "sampleRate:")
                if components.count > 1 {
                    let after = components[1]
                    let valStr = after.components(separatedBy: CharacterSet(charactersIn: " ,]")).first ?? ""
                    if let sr = Double(valStr) {
                        let stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
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
}
