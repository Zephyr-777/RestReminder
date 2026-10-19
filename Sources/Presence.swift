import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt

// MARK: - Presence Detection
/// 「人是否在电脑前用眼」的判定。
///
/// 只看键鼠空闲时长是不够的 —— 看视频、开线上会、盯着一页 PDF 思考时手可以
/// 十几分钟不动，但眼睛一直盯着屏幕。这种情况被判成「离开」，恰恰在最该提醒的
/// 时候沉默。所以这里额外引入两个可靠的系统信号来纠偏。
class PresenceDetector {
    /// Returns the seconds since last user input (keyboard or mouse)
    static func getIdleSeconds() -> Double {
        // 调试注入：存在 /tmp/rr_fake_idle 时，用文件里的秒数替代真实空闲时长。
        // 用来验证「离开判定」的各个分支 —— 真人坐在电脑前会不停产生事件，
        // 没法靠静置复现「离开 10 分钟」这种情况。
        //   用法：echo 400 > /tmp/rr_fake_idle   （验证；测完 rm 掉即可恢复真实值）
        if let raw = try? String(contentsOfFile: "/tmp/rr_fake_idle", encoding: .utf8),
           let fake = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return fake
        }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: ~UInt32(0))!
        )
    }

    /// 是否有进程持有「阻止显示器休眠」断言。
    ///
    /// 视频播放器、Keynote/PPT 演示模式、Zoom/腾讯会议在运行时都会持有它。
    /// 它比「鼠标有没有动」更能说明：屏幕上有内容在播，人正看着。
    static func hasDisplaySleepAssertion() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [String: Int] else { return false }
        return (d["PreventUserIdleDisplaySleep"] ?? 0) > 0
    }

    /// 显示器是否已休眠。注意返回的是 boolean_t(Int32)，不能直接当 Bool 用。
    static func isDisplayAsleep() -> Bool {
        return CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 屏幕锁定 / 已切走控制台（快速用户切换）—— 都是明确的「人不在」
    static func isScreenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = d["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
        return false
    }
}

enum Presence: Equatable {
    /// 在用眼（含正常操作间隔内的思考、阅读）
    case focusing
    /// 屏幕上有内容在播放（视频 / 演示 / 会议），仍按用眼计时
    case watching
    /// 判定离开，暂停计时
    case away(reason: AwayReason)

    enum AwayReason: String {
        case screenOff = "屏幕已熄灭"
        case locked = "屏幕已锁定"
        case noInput = "长时间无操作"
        case rested = "已自主休息"
    }
}
