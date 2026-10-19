import Cocoa

// MARK: - Break Overlay
/// 遮罩窗口：要能接管键盘（接收 Esc），并且盖得住菜单栏和全屏应用。
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
