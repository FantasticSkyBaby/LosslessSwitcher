import Foundation
import XCTest
import SimplyCoreAudio
import Combine
import CoreAudioTypes

@testable import LosslessSwitcher

final class TestOutputDevicesNoMonitoring: OutputDevices {
    var injectedStats: [CMPlayerStats] = []

    override func getAllStats() -> [CMPlayerStats] {
        return injectedStats
    }

    override func getDeviceSampleRate() {
        // 测试中禁用读取真实设备采样率，避免覆盖手动设置的 currentSampleRate
    }

    override func startHeartbeat() {
        // 测试中禁用心跳，避免后台触发 switchLatestSampleRate 影响结果
    }

    override func startMusicAppMonitoring() {
        // 测试中禁用 Music 通知监听，避免与测试用例耦合
    }
}

final class TestOutputDevicesWithMonitoring: OutputDevices {
    var injectedStats: [CMPlayerStats] = []

    override func getAllStats() -> [CMPlayerStats] {
        return injectedStats
    }

    override func getDeviceSampleRate() {
        // 测试中禁用读取真实设备采样率，避免覆盖手动设置的 currentSampleRate
    }

    override func startHeartbeat() {
        // 测试中禁用心跳，避免后台触发 switchLatestSampleRate 影响结果
    }
}

final class TestOutputDevicesFormatSelection: OutputDevices {
    var injectedStats: [CMPlayerStats] = []
    var injectedFormats: [AudioStreamBasicDescription] = []
    var appliedFormat: AudioStreamBasicDescription?
    var updatedSampleRate: Double?

    override func getAllStats() -> [CMPlayerStats] {
        return injectedStats
    }

    override func getDeviceSampleRate() {
        // 测试中禁用读取真实设备采样率，避免覆盖手动设置的 currentSampleRate
    }

    override func startHeartbeat() {
        // 测试中禁用心跳，避免后台触发 switchLatestSampleRate 影响结果
    }

    override func startMusicAppMonitoring() {
        // 测试中禁用 Music 通知监听，避免与测试用例耦合
    }

    override func getFormats(bestStat: CMPlayerStats, device: AudioDevice) -> [AudioStreamBasicDescription]? {
        return injectedFormats
    }

    override func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        appliedFormat = format
    }

    override func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        updatedSampleRate = sampleRate
    }
}

final class TestOutputDevicesPrebufferApply: OutputDevices {
    var injectedStats: [CMPlayerStats] = []
    var updatedSampleRate: Double?

    override func getAllStats() -> [CMPlayerStats] {
        return injectedStats
    }

    override func getDeviceSampleRate() {
    }

    override func startHeartbeat() {
    }

    override func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        updatedSampleRate = sampleRate
    }
}

final class TestOutputDevicesMusicDowngrade: OutputDevices {
    var injectedStats: [CMPlayerStats] = []
    var updatedSampleRate: Double?

    override func getAllStats() -> [CMPlayerStats] { injectedStats }
    override func getDeviceSampleRate() {}
    override func startHeartbeat() {}
    override func startMusicAppMonitoring() {}
    override func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        updatedSampleRate = sampleRate
    }
}

final class OutputDevicesPrebufferTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testSampleRateTextIncludesBitDepth() {
        let parts = SampleRateText.parts(sampleRateKHz: 48.0, bitDepth: 16)

        XCTAssertEqual(parts.rate, "48.0 kHz")
        XCTAssertEqual(parts.bit, "/ 16 bit")
    }

    func testSampleRateTextOmitsBitDepthWhenMissing() {
        let parts = SampleRateText.parts(sampleRateKHz: 48.0, bitDepth: nil)

        XCTAssertEqual(parts.rate, "48.0 kHz")
        XCTAssertNil(parts.bit)
    }

    func testBitDepthUpdatesWhenSampleRateUnchanged() {
        let devices = TestOutputDevicesNoMonitoring()

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        devices.currentSampleRate = 48.0
        devices.injectedStats = [
            CMPlayerStats(sampleRate: 48000, bitDepth: 16, date: Date(), priority: 5)
        ]

        devices.switchLatestSampleRate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(devices.currentBitDepth, 16)
    }

    func testBitDepthDoesNotPublishWhenUnchanged() {
        let devices = TestOutputDevicesNoMonitoring()

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        devices.currentSampleRate = 48.0
        devices.currentBitDepth = 24
        devices.injectedStats = [
            CMPlayerStats(sampleRate: 48000, bitDepth: 24, date: Date(), priority: 5)
        ]

        var publishCount = 0
        let cancellable = devices.$currentBitDepth
            .dropFirst()
            .sink { _ in
                publishCount += 1
            }

        devices.switchLatestSampleRate()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(publishCount, 0, "重复的位深度不应触发发布，避免菜单刷新")
        cancellable.cancel()
    }

    func testCoreMediaFigStreamPlayerLogParsesSampleRateAndBitDepth() {
        let message = "2026-02-07 14:49:23.030 Df Music[2049:1044136] [com.apple.coremedia:player] <<<< FigStreamPlayer >>>> fpfs_ReportAudioPlaybackThroughFigLog: [QE Critical][0xbbc674e00|P/RO]: <0xbc2646a00|I/JEA.01>: [AudioFormat qlac is  decodable] [AudioChannels 2] [Spatialization Eligible yes] [Client permits multi: no, stereo: no] [Spatialization no] [StereoSpatialization no] [Rendition Lossless] [SampleRate 44100] [BitDepth 24]"
        let entries = [SimpleConsole(date: Date(), message: message)]

        let stats = CMPlayerParser.parseCoreMediaConsoleLogs(entries)

        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.sampleRate ?? 0, 44100, accuracy: 0.001)
        XCTAssertEqual(stats.first?.bitDepth, 24)
        XCTAssertEqual(stats.first?.priority, 2)
    }

    func testLogStreamerKeepsLatestThreeTracks() {
        let streamer = LogStreamer.shared

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        streamer.updateCurrentTrackInfo(trackID: "1", trackName: "SongA")
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: Date(), priority: 5))

        streamer.updateCurrentTrackInfo(trackID: "2", trackName: "SongB")
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 48000, bitDepth: 24, date: Date(), priority: 5))

        streamer.updateCurrentTrackInfo(trackID: "3", trackName: "SongC")
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 96000, bitDepth: 24, date: Date(), priority: 5))

        streamer.updateCurrentTrackInfo(trackID: "4", trackName: "SongD")
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 88200, bitDepth: 24, date: Date(), priority: 5))

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(streamer.recentTracks.count, 3)
        XCTAssertEqual(streamer.recentTracks.first?.trackName, "SongD")
        XCTAssertEqual(streamer.recentTracks.last?.trackName, "SongB")
    }

    func testLogStreamerUpdatesCurrentTrackStats() {
        let streamer = LogStreamer.shared

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        streamer.updateCurrentTrackInfo(trackID: "1", trackName: "SongA")
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 44100, bitDepth: 16, date: Date(), priority: 5))
        streamer.appendDebugStat(CMPlayerStats(sampleRate: 44100, bitDepth: 24, date: Date(), priority: 5))

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(streamer.recentTracks.count, 1)
        XCTAssertEqual(streamer.recentTracks.first?.bitDepth, 24)
    }

    func testLogStreamerTracksNameChangesWithoutPersistentID() {
        let streamer = LogStreamer.shared

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        streamer.updateCurrentTrackInfo(trackID: nil, trackName: "SongA")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        streamer.updateCurrentTrackInfo(trackID: nil, trackName: "SongB")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let trackNames = streamer.recentTracks.map { $0.trackName }
        XCTAssertTrue(trackNames.contains("SongA"), "应包含 SongA")
        XCTAssertTrue(trackNames.contains("SongB"), "应包含 SongB")
        if let indexB = trackNames.firstIndex(of: "SongB"),
           let indexA = trackNames.firstIndex(of: "SongA") {
            XCTAssertTrue(indexB < indexA, "SongB 应在 SongA 之前（最近优先）")
        }
    }

    func testLogStreamerTracksNameChangesWithSamePersistentID() {
        let streamer = LogStreamer.shared

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        streamer.updateCurrentTrackInfo(trackID: "1", trackName: "SongA")
        streamer.updateCurrentTrackInfo(trackID: "1", trackName: "SongB")

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(streamer.recentTracks.count, 2)
        XCTAssertEqual(streamer.recentTracks.first?.trackName, "SongB")
        XCTAssertEqual(streamer.recentTracks.last?.trackName, "SongA")
    }

    func testDebugStatTextUsesProcessAndTrackName() {
        let date = Date(timeIntervalSince1970: 0)
        let entry = DebugTrackEntry(
            id: "1",
            trackName: "歌曲名",
            processName: "Music",
            sampleRate: 44100,
            bitDepth: 16,
            date: date
        )

        let lines = DebugStatText.lines(for: entry)

        XCTAssertEqual(lines.line1, "歌曲名")
        XCTAssertTrue(lines.line2.contains("44.1 kHz / 16 bit"))
        XCTAssertTrue(lines.line2.contains("音乐"))
    }

    func testDebugStatMenuTextHasTwoLines() {
        let date = Date(timeIntervalSince1970: 0)
        let entry = DebugTrackEntry(
            id: "1",
            trackName: "歌曲名",
            processName: "Music",
            sampleRate: 44100,
            bitDepth: 16,
            date: date
        )

        let text = DebugStatText.menuText(for: entry)

        XCTAssertTrue(text.contains("\n"))
        XCTAssertTrue(text.contains("歌曲名"))
        XCTAssertTrue(text.contains("44.1 kHz / 16 bit"))
        XCTAssertTrue(text.contains("音乐"))
    }
    func testBitDepthTogglePersistsToUserDefaults() {
        let defaults = Defaults.shared
        let key = "com.vincent-neo.LosslessSwitcher-Key-BitDepthDetection"

        let original = UserDefaults.standard.bool(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        defaults.userPreferBitDepthDetection = false
        defaults.userPreferBitDepthDetection.toggle()

        XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "Bit Depth 设置应在切换后写入 UserDefaults")
    }

    func testSelectedDeviceRestoresFromDefaults() {
        let defaults = Defaults.shared

        let coreAudio = SimplyCoreAudio()
        guard let device = coreAudio.allOutputDevices.first else {
            XCTFail("未找到可用输出设备，无法验证选中设备恢复逻辑")
            return
        }

        let originalUID = defaults.selectedDeviceUID
        defer { defaults.selectedDeviceUID = originalUID }

        defaults.selectedDeviceUID = device.uid

        let devices = TestOutputDevicesNoMonitoring()
        XCTAssertEqual(devices.selectedOutputDevice?.uid, device.uid, "启动时应根据保存的 UID 恢复选中设备")
    }

    func testSelectedDeviceClearsWhenDeviceRemoved() throws {
        let defaults = Defaults.shared
        let coreAudio = SimplyCoreAudio()
        let allDevices = coreAudio.allOutputDevices

        if allDevices.count < 2 {
            throw XCTSkip("输出设备数量不足，无法模拟设备移除")
        }

        let selected = allDevices[0]
        let remaining = allDevices.filter { $0.uid != selected.uid }

        let devices = TestOutputDevicesNoMonitoring()
        devices.selectedOutputDevice = selected
        defaults.selectedDeviceUID = selected.uid

        devices.outputDevices = remaining

        XCTAssertNil(devices.selectedOutputDevice, "设备被移除后应自动清空选中设备")
        XCTAssertNil(defaults.selectedDeviceUID, "设备被移除后应清空保存的 UID")
    }

    func testAppleMusicDoesNotAutoApplyPendingPrebufferAfterTimeout() {
        let devices = TestOutputDevicesWithMonitoring()

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        devices.defaultOutputDevice = nil
        devices.selectedOutputDevice = nil
        devices.currentSampleRate = 48.0

        let dnc = DistributedNotificationCenter.default()
        dnc.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil, userInfo: [
            "Player State": "Playing",
            "PersistentID": "1"
        ])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        Thread.sleep(forTimeInterval: 9.0)

        let oldDate = Date().addingTimeInterval(-20.0)
        devices.injectedStats = [CMPlayerStats(sampleRate: 44100, bitDepth: 24, date: oldDate, priority: 5)]

        devices.switchLatestSampleRate()
        XCTAssertNotNil(readPendingStat(in: devices), "预期 Apple Music 预缓冲日志被挂起")

        devices.switchLatestSampleRate()
        XCTAssertNotNil(readPendingStat(in: devices), "预期 Apple Music 播放中不应因 10s Safety Valve 自动应用")
    }

    func testAppleMusicPrebufferUsesTrackNameWhenNoTrackID() {
        let devices = TestOutputDevicesWithMonitoring()

        LogStreamer.shared.stop()
        LogStreamer.shared.latestStats = nil

        devices.defaultOutputDevice = nil
        devices.selectedOutputDevice = nil
        devices.currentSampleRate = 96.0

        let dnc = DistributedNotificationCenter.default()
        dnc.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil, userInfo: [
            "Player State": "Playing",
            "Name": "SongA"
        ])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        Thread.sleep(forTimeInterval: 9.0)

        devices.injectedStats = [
            CMPlayerStats(sampleRate: 44100, bitDepth: 24, date: Date(), priority: 5)
        ]

        devices.switchLatestSampleRate()

        XCTAssertNotNil(readPendingStat(in: devices), "预期无 trackID 时仍应根据曲名挂起预缓冲降级")
        XCTAssertEqual(devices.currentSampleRate, 96.0, "预期当前采样率保持不变")
    }

    func testSampleRateSwitchFindsFormatWithinTargetRate() {
        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        let defaults = Defaults.shared
        let originalBitDepthSetting = defaults.userPreferBitDepthDetection
        defaults.userPreferBitDepthDetection = true
        defer { defaults.userPreferBitDepthDetection = originalBitDepthSetting }

        let coreAudio = SimplyCoreAudio()
        guard let device = coreAudio.defaultOutputDevice else {
            XCTFail("未找到默认输出设备，无法验证采样率切换")
            return
        }

        guard let supportedRates = device.nominalSampleRates, supportedRates.count >= 2 else {
            XCTFail("输出设备采样率列表不足，无法构造测试场景")
            return
        }

        let highRate = supportedRates.max() ?? 48000
        let lowRate = supportedRates.min() ?? 44100

        if highRate == lowRate {
            XCTFail("输出设备采样率列表没有差异，无法构造切换场景")
            return
        }

        let devices = TestOutputDevicesFormatSelection()
        devices.defaultOutputDevice = device
        devices.selectedOutputDevice = device
        devices.currentSampleRate = highRate / 1000.0

        devices.injectedFormats = [
            AudioStreamBasicDescription(
                mSampleRate: highRate,
                mFormatID: 0,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 0,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 0,
                mBitsPerChannel: 24,
                mReserved: 0
            ),
            AudioStreamBasicDescription(
                mSampleRate: lowRate,
                mFormatID: 0,
                mFormatFlags: 0,
                mBytesPerPacket: 0,
                mFramesPerPacket: 0,
                mBytesPerFrame: 0,
                mChannelsPerFrame: 0,
                mBitsPerChannel: 16,
                mReserved: 0
            )
        ]

        devices.injectedStats = [
            CMPlayerStats(sampleRate: lowRate, bitDepth: 24, date: Date(), priority: 5)
        ]

        devices.switchLatestSampleRate()

        XCTAssertEqual(
            devices.updatedSampleRate,
            lowRate,
            "预期在目标采样率范围内找到可用格式并完成切换"
        )
    }

    func testPrebufferDowngradeAppliesWithoutRepeatedLowPriorityLogs() {
        let devices = TestOutputDevicesPrebufferApply()

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        let coreAudio = SimplyCoreAudio()
        guard let device = coreAudio.defaultOutputDevice else {
            XCTFail("未找到默认输出设备，无法验证采样率切换")
            return
        }

        guard let supportedRates = device.nominalSampleRates, supportedRates.count >= 2 else {
            XCTFail("输出设备采样率列表不足，无法构造测试场景")
            return
        }

        let highRate = supportedRates.max() ?? 48000
        let lowRate = supportedRates.min() ?? 44100

        if highRate == lowRate {
            XCTFail("输出设备采样率列表没有差异，无法构造切换场景")
            return
        }

        devices.defaultOutputDevice = device
        devices.selectedOutputDevice = device
        devices.currentSampleRate = highRate / 1000.0

        let dnc = DistributedNotificationCenter.default()
        dnc.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil, userInfo: [
            "Player State": "Playing",
            "PersistentID": "1"
        ])

        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        Thread.sleep(forTimeInterval: 9.0)

        devices.injectedStats = [
            CMPlayerStats(sampleRate: lowRate, bitDepth: 24, date: Date(), priority: 2)
        ]

        devices.switchLatestSampleRate()
        XCTAssertNotNil(readPendingStat(in: devices), "预期低优先级预缓冲日志被挂起")

        devices.injectedStats = []

        dnc.post(name: Notification.Name("com.apple.Music.playerInfo"), object: nil, userInfo: [
            "Player State": "Playing",
            "PersistentID": "2"
        ])

        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(
            devices.updatedSampleRate,
            lowRate,
            "预期切歌确认后即使日志未重复也应应用降级采样率"
        )
    }

    func testMusicDowngradeRequiresSustainedLowRateLogs() {
        let devices = TestOutputDevicesMusicDowngrade()

        LogStreamer.shared.stop()
        LogStreamer.shared.resetDebugStateForTests()

        devices.currentSampleRate = 96.0

        var high = CMPlayerStats(sampleRate: 96000, bitDepth: 24, date: Date(), priority: 5)
        high.processName = "Music"
        devices.injectedStats = [high]
        devices.switchLatestSampleRate()

        var low = CMPlayerStats(sampleRate: 44100, bitDepth: 24, date: Date(), priority: 5)
        low.processName = "Music"
        devices.injectedStats = [low]
        devices.switchLatestSampleRate()

        XCTAssertNil(devices.updatedSampleRate, "预期首次低码率日志仅挂起，不立即降级")

        Thread.sleep(forTimeInterval: 1.0)
        devices.switchLatestSampleRate()
        XCTAssertNil(devices.updatedSampleRate, "预期确认窗口内持续低码率仍不降级")

        Thread.sleep(forTimeInterval: 13.0)
        devices.switchLatestSampleRate()
        XCTAssertEqual(devices.updatedSampleRate, 44100, "预期低码率持续后才降级")
    }

    private func readPendingStat(in devices: OutputDevices) -> CMPlayerStats? {
        return readValue(named: "pendingNextTrackStat", from: devices)
    }

    private func readValue<T>(named name: String, from object: Any) -> T? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let current = mirror {
            for child in current.children {
                if child.label == name {
                    return unwrapOptional(child.value) as? T
                }
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }
}
