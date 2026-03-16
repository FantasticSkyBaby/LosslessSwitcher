//
//  AppConfig.swift
//  Quality
//
//  Created by FantasticSkyBaby on 2026/03/13.
//

import Foundation
import OSLog

struct AppConfig {
    /// 日志子系统
    static let subsystem = "com.vincent-neo.LosslessSwitcher"

    /// Apple Music 相关的切换策略参数
    struct Music {
        /// 会话有效期：在此时间内若无新日志，则认为当前音乐播放会话已结束
        static let sessionWindow: TimeInterval = 15.0
        /// 降级确认窗口：检测到码率下降时需持续观察的时间，防止因日志抖动导致的频繁切换
        static let downgradeConfirmWindow: TimeInterval = 2.0
        /// 高码率静默期：在高码率日志消失后，保持当前采样率的观察期
        static let highRateSilenceWindow: TimeInterval = 8.0
        /// 歌曲切换保护窗口：每首歌曲开始后的这段时间内（秒），对采样率变化进行严格校验（区分预加载与实际播放）
        static let trackChangeWindow: TimeInterval = 60.0
        /// 预加载数据有效期：捕获到的下一曲采样率信息若超过此时间未被应用，则视作失效
        static let prebufferExpiryWindow: TimeInterval = 3.0
        /// 提前切换阈值：当歌曲剩余时间少于此值时，立即应用预加载的采样率，实现零延时
        static let proactiveSwitchThreshold: TimeInterval = 1.5
    }
    
    /// 硬件切换相关的保护
    struct Switching {
        static let stabilityThresholdHz: Float64 = 1000.0
        static let stabilityCooldown: TimeInterval = 2.0
        static let upgradeRatioThreshold: Double = 1.05
        static let downgradePendingDelayLong: TimeInterval = 3.2
        static let downgradePendingDelayShort: TimeInterval = 1.2
    }
    
    /// 日志流配置
    struct LogStream {
        static let historyLimit = 5
        static let retryDelay: TimeInterval = 5.0
    }
}
