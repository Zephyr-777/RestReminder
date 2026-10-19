import Cocoa
import Foundation

// MARK: - Main Entry Point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// 调试入口：启动前 `touch /tmp/rr_preview.flag` 即可只播一遍动画且不熄屏。
// （不用命令行参数 —— 实测 `open --args` 传不进 bundle，argv 里只有可执行文件路径）
logDebug("启动参数: \(CommandLine.arguments)")
let previewFlagPath = "/tmp/rr_preview.flag"
let previewMicroFlagPath = "/tmp/rr_preview_micro.flag"
let sleepTestFlagPath = "/tmp/rr_sleeptest.flag"
if FileManager.default.fileExists(atPath: previewMicroFlagPath) {
    try? FileManager.default.removeItem(atPath: previewMicroFlagPath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        delegate.presentMicroBreakOverlay()
    }
} else if FileManager.default.fileExists(atPath: sleepTestFlagPath) {
    // 完整流程自测：动画走完真的熄屏
    try? FileManager.default.removeItem(atPath: sleepTestFlagPath)
    logDebug("进入熄屏自测：走完整流程（含熄屏）")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        delegate.presentSleepOverlay(forceSleep: true)
    }
} else if FileManager.default.fileExists(atPath: previewFlagPath) {
    try? FileManager.default.removeItem(atPath: previewFlagPath)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        delegate.presentSleepOverlay(forceSleep: false)
    }
}

app.run()
