//
//  ContentView.swift
//  Quality
//
//  Created by Vincent Neo on 18/4/22.
//

import SwiftUI
import OSLog
import SimplyCoreAudio

struct ContentView: View {
    @EnvironmentObject var outputDevices: OutputDevices
    
    var body: some View {
        VStack {
            if let currentSampleRate = outputDevices.currentSampleRate {
                let parts = SampleRateText.parts(sampleRateKHz: currentSampleRate,
                                                 bitDepth: outputDevices.currentBitDepth)
                if let bit = parts.bit {
                    (
                        Text(parts.rate)
                            .font(.system(size: 23, weight: .semibold, design: .default))
                        + Text(" ")
                        + Text(bit)
                            .font(.system(size: 20, weight: .semibold, design: .default))
                    )
                }
                else {
                    Text(parts.rate)
                        .font(.system(size: 23, weight: .semibold, design: .default))
                }
            }
            if let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice {
                Text(device.name)
                    .font(.system(size: 14.5, weight: .regular, design: .default))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
