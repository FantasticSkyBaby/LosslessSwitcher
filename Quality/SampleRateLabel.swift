//
//  SampleRateLabel.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI
import AppKit

struct SampleRateLabel: View {
    @EnvironmentObject private var outputDevices: OutputDevices

    var body: some View {
        let parts = SampleRateText.parts(sampleRateKHz: outputDevices.currentSampleRate,
                                         bitDepth: outputDevices.currentBitDepth)
        Image(nsImage: Self.renderStatusBarImage(rate: parts.rate, bit: parts.bit))
    }

    /// 将采样率文本渲染为 NSImage，文字底部对齐以匹配系统状态栏其他图标
    private static func renderStatusBarImage(rate: String, bit: String?) -> NSImage {
        let statusBarHeight: CGFloat = 22
        let bottomPadding: CGFloat = 3

        let rateFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bitFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

        let attributed = NSMutableAttributedString()

        attributed.append(NSAttributedString(string: rate, attributes: [
            .font: rateFont,
            .foregroundColor: NSColor.black
        ]))

        if let bit = bit {
            attributed.append(NSAttributedString(string: " ", attributes: [
                .font: rateFont,
                .foregroundColor: NSColor.black
            ]))
            attributed.append(NSAttributedString(string: bit, attributes: [
                .font: bitFont,
                .foregroundColor: NSColor.black
            ]))
        }

        let textSize = attributed.size()
        let imageWidth = ceil(textSize.width)

        let image = NSImage(size: NSSize(width: imageWidth, height: statusBarHeight), flipped: false) { _ in
            attributed.draw(at: NSPoint(x: 0, y: bottomPadding))
            return true
        }

        image.isTemplate = true
        return image
    }
}
