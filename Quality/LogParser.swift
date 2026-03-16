//
//  LogParser.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import Foundation
import OSLog

protocol LogParser {
    var identifier: String { get }
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats?
}

struct CoreAudioParser: LogParser {
    let identifier = "CoreAudio"
    
    // 更加宽松的正则匹配
    private static let sampleRateRegex = try? NSRegularExpression(pattern: #"ch,\s*([0-9]+)\s*Hz"#, options: [])
    private static let bitDepthRegex = try? NSRegularExpression(pattern: #"from\s*(\d+)-bit\s*source"#, options: [])
    
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats? {
        guard line.contains("ACAppleLosslessDecoder.cpp") && line.contains("Input format:") else { return nil }
        
        var sampleRate: Double?
        var bitDepth: Int?

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        
        if let match = CoreAudioParser.sampleRateRegex?.firstMatch(in: line, options: [], range: range),
           let rateRange = Range(match.range(at: 1), in: line) {
            sampleRate = Double(line[rateRange])
        }
        
        if let match = CoreAudioParser.bitDepthRegex?.firstMatch(in: line, options: [], range: range),
           let depthRange = Range(match.range(at: 1), in: line) {
            bitDepth = Int(line[depthRange])
        }
        
        if let sr = sampleRate, let bd = bitDepth {
            var stat = CMPlayerStats(sampleRate: sr, bitDepth: bd, date: Date(), priority: 5)
            stat.processName = extractProcessName(from: line)
            if isMusicProcess(stat.processName) {
                stat.trackName = currentTrackName
            }
            return stat
        }
        return nil
    }
}

struct CoreMediaParser: LogParser {
    let identifier = "CoreMedia"
    
    private static let fpfsRateRegex = try? NSRegularExpression(pattern: #"\[SampleRate\s*([0-9]+)\]"#, options: [])
    private static let fpfsDepthRegex = try? NSRegularExpression(pattern: #"\[BitDepth\s*(\d+)\]"#, options: [])
    private static let audioQueueRateRegex = try? NSRegularExpression(pattern: #"sampleRate:\s*([0-9.]+)"#, options: [])
    
    func parse(line: String, currentTrackName: String?) -> CMPlayerStats? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        
        if line.contains("fpfs_ReportAudioPlaybackThroughFigLog") {
            var sampleRate: Double?
            var bitDepth: Int?

            if let match = CoreMediaParser.fpfsRateRegex?.firstMatch(in: line, options: [], range: range),
               let rateRange = Range(match.range(at: 1), in: line) {
                sampleRate = Double(line[rateRange])
            }

            if let match = CoreMediaParser.fpfsDepthRegex?.firstMatch(in: line, options: [], range: range),
               let depthRange = Range(match.range(at: 1), in: line) {
                bitDepth = Int(line[depthRange])
            }

            if let sr = sampleRate {
                var stat = CMPlayerStats(sampleRate: sr, bitDepth: bitDepth ?? 24, date: Date(), priority: 2)
                stat.processName = extractProcessName(from: line)
                if isMusicProcess(stat.processName) {
                    stat.trackName = currentTrackName
                }
                return stat
            }
        }
        
        if line.contains("Creating AudioQueue") {
            if let match = CoreMediaParser.audioQueueRateRegex?.firstMatch(in: line, options: [], range: range),
               let rateRange = Range(match.range(at: 1), in: line) {
                if let sr = Double(line[rateRange]) {
                    var stat = CMPlayerStats(sampleRate: sr, bitDepth: 24, date: Date(), priority: 2)
                    stat.processName = extractProcessName(from: line)
                    if isMusicProcess(stat.processName) {
                        stat.trackName = currentTrackName
                    }
                    return stat
                }
            }
        }
        
        return nil
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

private func isMusicProcess(_ name: String?) -> Bool {
    guard let name = name?.lowercased() else { return false }
    return name == "music" || name == "itunes"
}
