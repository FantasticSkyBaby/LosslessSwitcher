//
//  MenuBarController.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 18/6/25.
//

import SwiftUI

class MenuBarController: ObservableObject {
    var outputDevices: OutputDevices!
    
    init() {
        let outputDevices = OutputDevices()
        self.outputDevices = outputDevices
    }
}
