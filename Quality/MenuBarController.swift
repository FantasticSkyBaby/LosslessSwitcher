//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import SwiftUI

class MenuBarController: ObservableObject {
    var outputDevices: OutputDevices!
    
    private var mrController: MediaRemoteController!
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
        self.mrController = MediaRemoteController(outputDevices: outputDevices)
    }
}
