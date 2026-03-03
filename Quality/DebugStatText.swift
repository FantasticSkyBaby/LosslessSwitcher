//
//  DebugStatText.swift
//  LosslessSwitcher
//
//  Created by Codex on 2026/02/07.
//

import Foundation

struct DebugTrackEntry: Identifiable {
    let id: String
    var trackName: String
    var processName: String?
    var sampleRate: Double?
    var bitDepth: Int?
    var date: Date?
}

struct DebugStatText {
    static func lines(for entry: DebugTrackEntry) -> (line1: String, line2: String) {
        let process = processDisplayName(processName: entry.processName)
        let title = entry.trackName.isEmpty ? process : entry.trackName
        let line1 = title

        let kHz: Float64? = entry.sampleRate.map { $0 / 1000.0 }
        let parts = SampleRateText.parts(sampleRateKHz: kHz, bitDepth: entry.bitDepth)

        var line2 = parts.rate
        if let bit = parts.bit {
            line2 += " \(bit)"
        }
        line2 += " · \(process)"
        if let date = entry.date {
            line2 += " · \(relativeTime(date))"
        }

        return (line1, line2)
    }

    static func menuText(for entry: DebugTrackEntry) -> String {
        let lines = lines(for: entry)
        return "\(lines.line1)\n\(lines.line2)"
    }

    static func relativeTime(_ date: Date) -> String {
        let elapsed = abs(Date().timeIntervalSince(date))
        if elapsed < 10 { return "刚刚" }
        if elapsed < 60 { return "\(Int(elapsed))s 前" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m 前" }
        return formatTime(date)
    }

    static func formatTime(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }

    static func processDisplayName(processName: String?) -> String {
        guard let name = processName, !name.isEmpty else {
            return "音频"
        }
        switch name.lowercased() {
        case "music", "itunes":
            return "音乐"
        default:
            return name
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
