//
//  SampleRateText.swift
//  LosslessSwitcher
//
//  Created by Codex on 2026/02/07.
//

import Foundation

struct SampleRateText {
    static func parts(sampleRateKHz: Float64?, bitDepth: Int?) -> (rate: String, bit: String?) {
        guard let sampleRateKHz else {
            return ("Unknown", nil)
        }

        let rate = String(format: "%.1f kHz", sampleRateKHz)
        guard let bitDepth else {
            return (rate, nil)
        }

        return (rate, "/ \(bitDepth) bit")
    }
}
