//
//  Logger.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import OSLog

extension Logger {
    static let streamer = Logger(subsystem: AppConfig.subsystem, category: "Streamer")
    static let policy = Logger(subsystem: AppConfig.subsystem, category: "Policy")
    static let hardware = Logger(subsystem: AppConfig.subsystem, category: "Hardware")
    static let ui = Logger(subsystem: AppConfig.subsystem, category: "UI")
}
