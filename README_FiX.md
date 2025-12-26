# LosslessSwitcher (macOS 15+ Fix) / macOS 15+ 修复版

**Author / 作者:** FantasticSkyBaby  
**Date / 日期:** 2025-12-19

---

## English

### Overview
This is a modified version of LosslessSwitcher designed to fix compatibility issues with **macOS 15 (Sequoia)** and newer.

The original application relied on the `OSLogStore` API to read system audio logs and detect sample rate changes. In macOS 15, Apple restricted access to these system logs for third-party applications, causing the original version to fail (it could not detect track changes or sample rates).

This version introduces a new **hybrid detection engine** that bypasses these restrictions.https://github.com/vincentneo/LosslessSwitcher/issues/195#issuecomment-3691938163

### Key Changes

1.  **LogStreamer (Real-time Log Parsing)**
    *   **Mechanism**: Instead of using the restricted Swift API, we spawn a background process running the native `/usr/bin/log stream` command.
    *   **Target**: Filters for `com.apple.coreaudio`, `com.apple.music`, and `com.apple.coremedia`.
    *   **Benefit**: Successfully captures real-time sample rate changes from `coreaudiod` that are otherwise invisible to standard apps on macOS 15.

2.  **AppleScript Fallback**
    *   **Mechanism**: If log data is unavailable (e.g., due to specific stream types or further system locking), the app directly queries the **Music** app via AppleScript (`tell application "Music" to get sample rate of current track`).
    *   **Benefit**: Provides a reliable "fail-safe" method to ensure the sample rate eventually switches, even if real-time logs are missing.

3.  **Heartbeat Monitor**
    *   **Mechanism**: Implemented a 2-second heartbeat timer that actively polls for state changes.
    *   **Benefit**: Ensures the app recovers and switches correctly even if the system's "Now Playing" notifications are delayed or missed.

### Requirements
*   **macOS**: 13.5.0+ (Optimized for macOS 15+) Intel and Apple Silicon
*   **Permissions**:
    *   **Automation**: The app will request permission to control "Music.app" (for the AppleScript fallback). **You must allow this.**

---

## 中文 (Chinese)

### 简介
这是 LosslessSwitcher 的修改版本，旨在修复 **macOS 15 (Sequoia)** 及更高版本上的兼容性问题。

原版应用依赖 `OSLogStore` API 读取系统音频日志来检测采样率变化。在 macOS 15 中，Apple 限制了第三方应用访问这些系统日志的权限，导致原版无法检测到曲目变更或采样率信息，从而失效。

此版本引入了一个全新的 **混合检测引擎** 来绕过这些限制。https://github.com/vincentneo/LosslessSwitcher/issues/195#issuecomment-3691938163

### 主要修改

1.  **LogStreamer (实时日志流解析)**
    *   **机制**：不再使用受限的 Swift API，而是在后台启动一个运行原生 `/usr/bin/log stream` 命令的子进程。
    *   **目标**：过滤并监听 `com.apple.coreaudio`、`com.apple.music` 和 `com.apple.coremedia` 的日志。
    *   **优势**：成功捕获 `coreaudiod` 的实时采样率变化，这些信息在 macOS 15 上对普通应用通常是不可见的。

2.  **AppleScript 回退机制 (保底方案)**
    *   **机制**：如果日志数据不可用（例如由于特定的流媒体类型或系统进一步锁定），应用会直接通过 AppleScript 向 **音乐 (Music)** 应用查询：`tell application "Music" to get sample rate of current track`。
    *   **优势**：提供了一种可靠的“故障安全”方法，即使实时日志缺失，也能确保采样率最终能够正确切换。

3.  **心跳监测 (Heartbeat)**
    *   **机制**：实现了一个每 2 秒运行一次的心跳通过定时器，主动轮询状态变化。
    *   **优势**：即使系统的“正在播放”通知延迟或丢失，也能确保应用恢复并正确切换采样率。

### 系统要求与权限
*   **macOS**: 13.5.0+ (针对 macOS 15+ 进行了优化) Intel and Apple Silicon
*   **权限**:
    *   **自动化 (Automation)**: 应用会请求控制 "Music.app" 的权限（用于 AppleScript 回退）。**您必须点击“允许”**，否则自动切换可能偶尔失效。

---
*Original project by Vincent Neo. Fixes by FantasticSkyBaby.*
