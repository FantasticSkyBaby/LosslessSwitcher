//
//  LogStreamer.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import Combine
import Foundation
import Sweep
import OSLog

class LogStreamer: ObservableObject {
    static let shared = LogStreamer()
    private var process: Process?
    private var pipe: Pipe?
    private var errorPipe: Pipe?
    private var isExplicitlyStopped = false
    private var isRestarting = false
    
    @Published var latestStats: CMPlayerStats?
    @Published var recentTracks: [DebugTrackEntry] = []
    private(set) var statGeneration: UInt64 = 0
    private let debugHistoryLimit = AppConfig.LogStream.historyLimit
    private var currentTrackID: String?
    private var currentTrackName: String?
    private var currentTrackSignature: String?
    private var currentTrackStartTime: Date?
    
    private var parsers: [LogParser] = [CoreAudioParser(), CoreMediaParser()]
    
    private init() {}

    func register(parser: LogParser) {
        parsers.append(parser)
    }

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

            var didChangeTrack = false
            
            if let id = normalizedID, !id.isEmpty, let knownID = self.currentTrackID, id != knownID {
                didChangeTrack = true
            } else if let name = normalizedName, !name.isEmpty, let knownName = self.currentTrackName, name != knownName {
                didChangeTrack = true
            } else if self.currentTrackID == nil && self.currentTrackName == nil {
                didChangeTrack = true
            }
            
            if didChangeTrack {
                self.currentTrackID = normalizedID
                self.currentTrackStartTime = now
                if let name = normalizedName, !name.isEmpty {
                    self.currentTrackName = name
                }
                
                let nameForEntry = self.currentTrackName ?? "Unknown"
                let key = self.makeTrackKey(id: self.currentTrackID, name: self.currentTrackName) ?? (self.currentTrackID ?? nameForEntry)
                
                let wasNameEmpty = self.currentTrackSignature == nil
                
                if wasNameEmpty, let oldKey = self.currentTrackSignature, oldKey != key {
                    self.currentTrackSignature = key
                    self.replaceTrackEntryKey(oldKey: oldKey, newKey: key, trackName: nameForEntry, date: now)
                } else {
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
                }
            } else {
                // Not a track change, just populating missing info
                var infoUpdated = false
                if let id = normalizedID, !id.isEmpty, self.currentTrackID == nil {
                    self.currentTrackID = id
                    infoUpdated = true
                }
                if let name = normalizedName, !name.isEmpty, self.currentTrackName == nil {
                    self.currentTrackName = name
                    infoUpdated = true
                }
                
                if infoUpdated {
                    let nameForEntry = self.currentTrackName ?? "Unknown"
                    let newKey = self.makeTrackKey(id: self.currentTrackID, name: self.currentTrackName) ?? (self.currentTrackID ?? nameForEntry)
                    
                    if let oldKey = self.currentTrackSignature, oldKey != newKey {
                        self.currentTrackSignature = newKey
                        self.replaceTrackEntryKey(oldKey: oldKey, newKey: newKey, trackName: nameForEntry, date: now)
                    } else if self.currentTrackSignature == nil {
                        self.currentTrackSignature = newKey
                    }
                }
            }
        }
    }
    
    func start() {
        if isRestarting { return }
        isExplicitlyStopped = false
        stopProcess()
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--predicate",
            "(subsystem == \"com.apple.coreaudio\" OR subsystem == \"com.apple.coremedia\")",
            "--style", "compact"
        ]
        
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        self.pipe = pipe
        self.errorPipe = errorPipe
        self.process = process
        
        process.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            
            // 如果是主动停止或正在重启过程中触发的旧进程退出，直接忽略
            if self.isExplicitlyStopped || self.isRestarting {
                return
            }
            
            Logger.streamer.error("[LogStreamer] Process terminated with status: \(proc.terminationStatus). Reason: \(proc.terminationReason.rawValue)")
            
            // 尝试读取错误输出
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                Logger.streamer.error("[LogStreamer] Stderr: \(errStr, privacy: .public)")
            }

            self.isRestarting = true
            Logger.streamer.info("[LogStreamer] Restarting in \(AppConfig.LogStream.retryDelay)s...")
            DispatchQueue.global().asyncAfter(deadline: .now() + AppConfig.LogStream.retryDelay) {
                self.isRestarting = false
                self.start()
            }
        }
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let string = String(data: data, encoding: .utf8) {
                self?.processOutput(string)
            }
        }
        
        do {
            try process.run()
            Logger.streamer.info("[LogStreamer] Log stream started successfully.")
        } catch {
            Logger.streamer.error("[LogStreamer] Failed to run log process: \(error, privacy: .public)")
        }
    }
    
    func stop() {
        isExplicitlyStopped = true
        stopProcess()
    }

    private func stopProcess() {
        if process?.isRunning == true {
            // 在 terminate 前设置 isRestarting 为 true，防止触发自身的 terminationHandler 重启
            self.isRestarting = true 
            process?.terminate()
            self.isRestarting = false
        }
        process = nil
        pipe = nil
        errorPipe = nil
    }
    
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.isEmpty { continue }
            
            for parser in parsers {
                if let stat = parser.parse(line: line, currentTrackName: self.currentTrackName) {
                    self.appendDebugStat(stat)
                    break
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
            
            let playedTime = Date().timeIntervalSince(self.currentTrackStartTime ?? Date())
            let isMusic = isMusicProcess(processName ?? entry.processName)
            let isLocked = isMusic && playedTime > AppConfig.Music.trackChangeWindow && (entry.sampleRate != nil)
            
            if isLocked, let newSR = sampleRate, newSR != entry.sampleRate {
                recentTracks.insert(entry, at: 0)
                return
            }
            
            entry.trackName = trackName
            entry.processName = processName ?? entry.processName
            if let sampleRate { entry.sampleRate = sampleRate }
            if let bitDepth, bitDepth > 0 { entry.bitDepth = bitDepth }
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
                bitDepth: (bitDepth ?? 0) > 0 ? bitDepth : nil,
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
