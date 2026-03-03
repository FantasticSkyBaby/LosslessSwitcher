//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    @ObservedObject private var logStreamer = LogStreamer.shared
    
    var body: some View {
        VStack {
            ContentView()
            
            Divider()
            
            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }
            
            Button {
                defaults.userPreferBitDepthDetection.toggle()
            } label: {
                HStack {
                    Text("Bit Depth Switching")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                defaults.userPreferDebugMenu.toggle()
            } label: {
                HStack {
                    Text("Debug Logs")
                    if defaults.userPreferDebugMenu {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if defaults.userPreferDebugMenu {
                Divider()

                if logStreamer.recentTracks.isEmpty {
                    Text("No Data")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                ForEach(Array(logStreamer.recentTracks.filter { $0.sampleRate != nil && !$0.trackName.isEmpty && $0.trackName != "Unknown" }.enumerated()), id: \.offset) { index, entry in
                    let lines = DebugStatText.lines(for: entry)
                    (
                        Text(lines.line1 + "\n")
                            .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                        + Text(lines.line2)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    )
                }
            }
            
            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("Default Device")
                }

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
                    Button {
                        outputDevices.selectedOutputDevice = device
                        defaults.selectedDeviceUID = device.uid
                    } label: {
                        Text(device.name)
                        if outputDevices.selectedOutputDevice?.uid == device.uid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("Selected Device")
            }
            
            Menu {
                Text("FixedBy - FantasticSkyBaby")
                Text("Version - \(currentVersion)")
                Text("Build - \(currentBuild)")
                
            } label: {
                Text("About")
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit LosslessSwitcher")
            }
        }
    }
}
