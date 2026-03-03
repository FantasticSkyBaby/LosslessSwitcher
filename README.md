# LosslessSwitcher (通用版) / Universal Audio Sample Rate Switcher

<img width="736" height="784" alt="CleanShot 2026-03-03 at 4  54 55@2x" src="https://github.com/user-attachments/assets/ce43c55f-440b-4d48-abba-873d50dc311e" />


## 中文 (Chinese)

### 简介
这是 LosslessSwitcher 的**通用版本**，可以自动为**任何音频播放器**切换系统音频输出采样率。

与原版不同，本版本**不依赖 Apple Music**，而是通过监听系统级的 CoreAudio 日志来检测音频流的采样率变化，因此支持：
- ✅ **Apple Music** (本地文件和流媒体)
- ✅ **Spotify**
- ✅ **VLC Media Player**
- ✅ **网页播放器** (YouTube Music, Tidal, Qobuz 等)
- ✅ **其他任何音频播放器**

### 工作原理

应用通过以下方式检测音频采样率：

1. **LogStreamer (实时日志流解析)**
   - **机制**：在后台启动一个运行原生 `/usr/bin/log stream` 命令的子进程
   - **目标**：过滤并监听 `com.apple.coreaudio` 和 `com.apple.coremedia` 的系统日志
   - **优势**：捕获所有播放器的音频流信息，不限于特定应用

2. **CoreAudio 解码器检测**
   - 监听 `ACAppleLosslessDecoder.cpp` 的日志输出
   - 可获取精确的采样率和位深度信息
   - 优先级最高，最可靠

3. **CoreMedia AudioQueue 检测**
   - 作为备用检测源
   - 提供基本的采样率信息

### 主要特性

- 🎵 **通用兼容**：支持所有音频播放器，不限于 Apple Music
- ⚡ **自动切换**：检测到采样率变化时自动调整音频输出设备
- 🎯 **智能防抖**：避免误检测和频繁切换
- 🔋 **低功耗**：优化的检测逻辑，降低系统资源占用
- 🛡️ **稳定播放**：播放过程中防止意外降级

### 系统要求与权限

- **macOS**: 13.5.0+ (针对 macOS 15+ 进行了优化) Intel 和 Apple Silicon
- **权限**:
  - **管理员权限**: 需要管理员权限来访问系统日志
  - **不需要自动化权限**: 与原版不同，本版本不需要控制 Music.app 的权限

### 使用说明

1. ✅启动应用后，它会在菜单栏显示当前采样率
2. ✅播放任何音频内容时，应用会自动检测并切换采样率
3. ✅支持的采样率：44.1kHz, 48kHz, 88.2kHz, 96kHz, 176.4kHz, 192kHz 等

### 注意事项

- ⚠️ 本版本**不显示曲目信息**（歌名、艺术家等），仅专注于采样率切换
- ✅ 相比原版更轻量，功耗更低

### 版本信息

- **原版作者**: Vincent Neo
- **改造作者**: FantasticSkyBaby
- **改造日期**: 2026-01-15
- **版本号**: 4.0 (通用版)
- **版本号**: 3.0 (Apple Music依赖版)
- **版本号**: 2.0 (原版)

---

## English

### Overview
This is a **universal version** of LosslessSwitcher that automatically switches system audio output sample rate for **any audio player**.

Unlike the original version, this build **does not depend on Apple Music**. Instead, it monitors system-level CoreAudio logs to detect audio stream sample rate changes, supporting:
- ✅ **Apple Music** (local files and streaming)
- ✅ **Spotify**
- ✅ **VLC Media Player**
- ✅ **Web Players** (YouTube Music, Tidal, Qobuz, etc.)
- ✅ **Any other audio player**

### How It Works

The application detects audio sample rates through:

1. **LogStreamer (Real-time Log Parsing)**
   - **Mechanism**: Spawns a background process running the native `/usr/bin/log stream` command
   - **Target**: Filters and monitors `com.apple.coreaudio` and `com.apple.coremedia` system logs
   - **Benefit**: Captures audio stream information from all players, not limited to specific apps

2. **CoreAudio Decoder Detection**
   - Monitors `ACAppleLosslessDecoder.cpp` log output
   - Provides precise sample rate and bit depth information
   - Highest priority, most reliable

3. **CoreMedia AudioQueue Detection**
   - Serves as a fallback detection source
   - Provides basic sample rate information

### Key Features

- 🎵 **Universal Compatibility**: Supports all audio players, not limited to Apple Music
- ⚡ **Automatic Switching**: Automatically adjusts audio output device when sample rate changes are detected
- 🎯 **Smart Debouncing**: Avoids false detections and frequent switching
- 🔋 **Low Power**: Optimized detection logic reduces system resource usage
- 🛡️ **Stable Playback**: Prevents accidental downgrades during playback

### Requirements & Permissions

- **macOS**: 13.5.0+ (Optimized for macOS 15+) Intel and Apple Silicon
- **Permissions**:
  - **Administrator Privileges**: Required to access system logs
  - **No Automation Permission Needed**: Unlike the original, this version doesn't need to control Music.app

### Usage

1. After launching, the app displays the current sample rate in the menu bar
2. When playing any audio content, the app automatically detects and switches the sample rate
3. Supported sample rates: 44.1kHz, 48kHz, 88.2kHz, 96kHz, 176.4kHz, 192kHz, etc.

### Notes

- ⚠️ This version **does not display track information** (song name, artist, etc.), focusing solely on sample rate switching
- ✅ More lightweight and lower power consumption compared to the original

### Version Information

- **Original Author**: Vincent Neo
- **Universal Version Author**: FantasticSkyBaby
- **Transformation Date**: 2026-01-15
- **Version Number**: 4.0 (Major architecture change)
- **Version Number**: 3.0 (Apple Music dependency version)
- **Version Number**: 2.0 (Original version)

---
