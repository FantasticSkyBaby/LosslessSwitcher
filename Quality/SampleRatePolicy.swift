//
//  SampleRatePolicy.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import Foundation
import Combine

struct PolicyResult {
    let shouldApply: Bool
    let stat: CMPlayerStats?
    let bypassDowngradeProtection: Bool
    let reason: String
}

class SampleRatePolicy: ObservableObject {
    static let shared = SampleRatePolicy()
    
    // 内部状态 (迁移自 OutputDevices)
    private(set) var lastTrackChangeDate: Date = Date.distantPast
    private(set) var lastKnownTrackID: String?
    private(set) var lastKnownTrackName: String?
    private var currentTrackPlayedTime: TimeInterval = 0
    private var lastPlaybackSnapshot: Date?
    private var isMusicPlaying: Bool = false
    
    private var pendingNextTrackStat: CMPlayerStats?
    private var pendingNextTrackStatLastSeen: Date?
    
    private var pendingMusicDowngradeStat: CMPlayerStats?
    private var pendingMusicDowngradeDetectedAt: Date?
    private var pendingMusicDowngradeLastSeen: Date?
    
    private var lastMusicLogAt: Date?
    private var lastMusicHighRateAt: Date?
    
    private var lastProcessedGeneration: UInt64 = 0
    private var lastProcessedStatDate: Date?
    private var lastDetectedSampleRate: Float64?

    private init() {}

    @discardableResult
    func updateMusicState(isPlaying: Bool, trackID: String?, trackName: String?) -> Bool {
        let wasPlaying = self.isMusicPlaying
        self.isMusicPlaying = isPlaying
        
        if !wasPlaying && isPlaying {
            self.lastPlaybackSnapshot = Date()
        } else if wasPlaying && !isPlaying {
            if let snapshot = self.lastPlaybackSnapshot {
                self.currentTrackPlayedTime += Date().timeIntervalSince(snapshot)
                self.lastPlaybackSnapshot = nil
            }
        }
        
        var didChangeTrack = false
        
        if let id = trackID, let knownID = lastKnownTrackID, id != knownID {
            // Track ID changed
            handleTrackChange(newID: id, newName: trackName)
            didChangeTrack = true
        } else if let name = trackName, let knownName = lastKnownTrackName, name != knownName {
            // Track Name changed (fallback if ID is missing)
            handleTrackChange(newID: trackID, newName: name)
            didChangeTrack = true
        } else if lastKnownTrackID == nil && lastKnownTrackName == nil {
            // Initial state
            handleTrackChange(newID: trackID, newName: trackName)
            didChangeTrack = true
        }
        
        // Ensure we populate nil fields if they arrive later for the same track
        if !didChangeTrack {
            if trackID != nil && self.lastKnownTrackID == nil {
                self.lastKnownTrackID = trackID
            }
            if trackName != nil && self.lastKnownTrackName == nil {
                self.lastKnownTrackName = trackName
            }
        }
        
        return didChangeTrack
    }
    
    private func handleTrackChange(newID: String?, newName: String?) {
        self.lastKnownTrackID = newID
        self.lastKnownTrackName = newName
        self.currentTrackPlayedTime = 0
        self.lastPlaybackSnapshot = isMusicPlaying ? Date() : nil
        self.lastTrackChangeDate = Date()
        
        self.pendingMusicDowngradeStat = nil
        self.pendingMusicDowngradeDetectedAt = nil
        self.pendingMusicDowngradeLastSeen = nil
    }

    func getEffectivePlayedTime() -> TimeInterval {
        var played = currentTrackPlayedTime
        if isMusicPlaying, let snapshot = lastPlaybackSnapshot {
            played += Date().timeIntervalSince(snapshot)
        }
        return played
    }

    func evaluate(currentHz: Float64, latestStat: CMPlayerStats) -> PolicyResult {
        let now = Date()
        
        let playedTime = self.getEffectivePlayedTime()
        let inFirst60s = playedTime < AppConfig.Music.trackChangeWindow
        
        // 核心要求：超过 60 秒后，彻底禁止所有码率切换（只允许存储预缓冲）
        if !inFirst60s {
            if abs(latestStat.sampleRate - currentHz) > 100 {
                if self.pendingNextTrackStatLastSeen == nil || latestStat.date > self.pendingNextTrackStatLastSeen! {
                    self.pendingNextTrackStat = latestStat
                    self.pendingNextTrackStatLastSeen = latestStat.date
                }
            }
            return PolicyResult(shouldApply: false, stat: nil, bypassDowngradeProtection: false, reason: "Locked: post-60s playback")
        }

        // 只有在前 60 秒内，才允许执行以下所有的码率切换逻辑
        
        // 1. 核心修复：切歌瞬间立即应用预缓冲数据，跳过一切后续检查
        if let pending = self.pendingNextTrackStat {
            self.pendingNextTrackStat = nil
            self.pendingNextTrackStatLastSeen = nil
            return PolicyResult(shouldApply: true, stat: pending, bypassDowngradeProtection: true, reason: "Applying pre-buffered rate on track change")
        }
        
        let first = latestStat

        // 3. 过滤陈旧日志（上一首歌产生的日志）
        if first.date < self.lastTrackChangeDate {
            return PolicyResult(shouldApply: false, stat: nil, bypassDowngradeProtection: false, reason: "Stale log (pre-track change)")
        }

        let currentGen = LogStreamer.shared.statGeneration
        let isNewStat = currentGen != self.lastProcessedGeneration
        self.lastProcessedGeneration = currentGen
        self.lastProcessedStatDate = first.date
        self.lastDetectedSampleRate = first.sampleRate
        
        let isMusicStat = isMusicProcessName(first.processName)
        if isMusicStat, isNewStat {
            lastMusicLogAt = now
            if abs(first.sampleRate - currentHz) < 100 {
                lastMusicHighRateAt = now
            }
        }
        
        let isMusicSessionActive = lastMusicLogAt.map { now.timeIntervalSince($0) < AppConfig.Music.sessionWindow } ?? false
        let isTrackJustChangedWindow = now.timeIntervalSince(self.lastTrackChangeDate) < 3.0
        
        // 4. 前60秒内，区分升频和降频
        if isMusicStat || isMusicPlaying {
            if first.sampleRate > currentHz + 100 {
                // 升频：直接放行
                pendingMusicDowngradeStat = nil
                pendingMusicDowngradeDetectedAt = nil
                return PolicyResult(shouldApply: true, stat: first, bypassDowngradeProtection: true, reason: "Immediate upgrade allowed within 60s window")
            } else if first.sampleRate < currentHz - 100 {
                // 降频
                if isTrackJustChangedWindow {
                    // 切歌初期的 3 秒内，无视降级保护以保证体验
                    return PolicyResult(shouldApply: true, stat: first, bypassDowngradeProtection: true, reason: "Immediate downgrade on track change")
                }
                
                // 不在切歌初期，可能是在高码率歌曲播放中突发的虚假低码率日志（日志抖动），需走确认逻辑
                let isNewPending = pendingMusicDowngradeStat == nil || abs((pendingMusicDowngradeStat?.sampleRate ?? 0) - first.sampleRate) > 1
                if isNewPending {
                    pendingMusicDowngradeStat = first
                    pendingMusicDowngradeDetectedAt = now
                    pendingMusicDowngradeLastSeen = now
                    return PolicyResult(shouldApply: false, stat: nil, bypassDowngradeProtection: false, reason: "Starting downgrade confirmation window")
                }
                
                if let detectedAt = pendingMusicDowngradeDetectedAt, now.timeIntervalSince(detectedAt) >= AppConfig.Music.downgradeConfirmWindow {
                    pendingMusicDowngradeStat = nil
                    pendingMusicDowngradeDetectedAt = nil
                    return PolicyResult(shouldApply: true, stat: first, bypassDowngradeProtection: false, reason: "Downgrade confirmed")
                }
                return PolicyResult(shouldApply: false, stat: nil, bypassDowngradeProtection: false, reason: "Confirming downgrade...")
            } else {
                // 采样率一致
                pendingMusicDowngradeStat = nil
                pendingMusicDowngradeDetectedAt = nil
            }
        }
        
        return PolicyResult(shouldApply: true, stat: first, bypassDowngradeProtection: false, reason: "Standard application")
    }
    
    private func isMusicProcessName(_ name: String?) -> Bool {
        guard let name = name?.lowercased() else { return false }
        return name == "music" || name == "itunes"
    }
}
