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
    
    func switchLatestSampleRate(recursion: Bool = false) {
        var allStats = self.getAllStats()
        
        if allStats.isEmpty, let scriptRate = self.getSampleRateFromAppleScript() {
            let rateHz = scriptRate < 384.0 ? scriptRate * 1000.0 : scriptRate
            // Fallback to AppleScript rate
            // Use 24-bit depth as a safe default for High Res Lossless
            let stat = CMPlayerStats(sampleRate: rateHz, bitDepth: 24, date: Date(), priority: 0)
            allStats.append(stat)
        }

        if let streamedStat = LogStreamer.shared.latestStats {
             // If manual polling failed or LogStreamer has fresher/better data
             // We prioritize LogStreamer if it's recent enough
             let timeDiff = abs(Date().timeIntervalSince(streamedStat.date))
             if timeDiff < 10.0 { 
                 allStats.insert(streamedStat, at: 0)
             }
        }
        
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        
        if let first = allStats.first, let supported = defaultDevice?.nominalSampleRates {
            let sampleRate = Float64(first.sampleRate)
            let bitDepth = Int32(first.bitDepth)
            
            if self.currentTrack == self.previousTrack, let prevSampleRate = currentSampleRate, prevSampleRate > sampleRate {
                // same track, prev sample rate is higher, ignore
                return
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
                else if suitableFormat.mSampleRate != previousSampleRate { // bit depth disabled
                    defaultDevice?.setNominalSampleRate(suitableFormat.mSampleRate)
                }
                self.updateSampleRate(suitableFormat.mSampleRate)
                if let currentTrack = currentTrack {
                    self.trackAndSample[currentTrack] = suitableFormat.mSampleRate
                }
            }

//            if let nearest = nearest {
//                let nearestSampleRate = nearest.element
//                if nearestSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(nearestSampleRate)
//                    self.updateSampleRate(nearestSampleRate)
//                    if let currentTrack = currentTrack {
//                        self.trackAndSample[currentTrack] = nearestSampleRate
//                    }
//                }
//            }
        }
        else if !recursion {
            processQueue.asyncAfter(deadline: .now() + 1) {
                self.switchLatestSampleRate(recursion: true)
            }
        }
        else {
//                print("cache \(self.trackAndSample)")
            if self.currentTrack == self.previousTrack {
                print("same track, ignore cache")
                return
            }
//            if let currentTrack = currentTrack, let cachedSampleRate = trackAndSample[currentTrack] {
//                print("using cached data")
//                if cachedSampleRate != previousSampleRate {
//                    defaultDevice?.setNominalSampleRate(cachedSampleRate)
//                    self.updateSampleRate(cachedSampleRate)
//                }
//            }
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
    
    func trackDidChange(_ newTrack: TrackInfo) {
        self.previousTrack = self.currentTrack
        self.currentTrack = MediaTrack(trackInfo: newTrack)
        if self.previousTrack != self.currentTrack {
            self.renewTimer()
        }
        processQueue.async { [unowned self] in
            self.switchLatestSampleRate()
        }
    }
}

import Sweep

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
        // We use --style compact to make parsing somewhat predictable, though plain text is default
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
            print("[LogStreamer] Started log stream process")
        } catch {
            print("[LogStreamer] Failed to start log stream: \(error)")
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
            
            // CoreAudio parsing
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
            
            // Music parsing
            if line.contains("audioCapabilities:") {
                 // "asbdSampleRate = 48 kHz"
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
            
            // CoreMedia parsing
             if line.contains("Creating AudioQueue") && line.contains("sampleRate:") {
                 if let subSampleRate = line.firstSubstring(between: "sampleRate:", and: .end) { // end might fail if not sweep compatible end
                     // Try simpler parsing
                     let str = String(subSampleRate)
                     // " Creating AudioQueue ... sampleRate:48000.0 ..."
                     // The sweep 'end' might match end of string.
                     // Often it's "sampleRate:48000.0 "
                     let scanners = Scanner(string: str)
                     if let sr = scanners.scanDouble() {
                         let stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                         self.updateStats(stat)
                         continue
                     }
                 }
                 // Fallback parsing for CoreMedia
                 // format: "sampleRate:48000.0" possibly followed by space or comma
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
