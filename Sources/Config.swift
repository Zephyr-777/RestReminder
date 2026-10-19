import Foundation
import CoreGraphics

// MARK: - 配置键

/// UserDefaults 的键名，集中在这里，避免散落各处的字符串字面量打错。
struct ConfigKeys {
    static let targetMinutes = "targetMinutes"
    static let soundEnabled = "soundEnabled"
    static let voiceEnabled = "voiceEnabled"
    static let autostartEnabled = "autostartEnabled"
    /// 到点是否弹全屏休息提醒
    static let forceSleepEnabled = "forceSleepEnabled"
    /// 熄屏前全屏提醒的停留秒数
    static let forceSleepLeadSeconds = "forceSleepLeadSeconds"
    /// 无输入多久算离开（秒）
    static let awayThresholdSeconds = "awayThresholdSeconds"
    /// 提醒动画播完后，是否落进循环休息画面（伪熄屏）
    static let loopVideoEnabled = "loopVideoEnabled"
    /// 循环休息画面的倒计时时长（分钟）。设为 0 表示不限时
    static let restCountdownMinutes = "restCountdownMinutes"
    /// 收起休息画面时的淡出时长（秒）。一般不用改，验证过渡动画时会临时调大
    static let dismissFadeSeconds = "dismissFadeSeconds"
    
    // MARK: - 微休息（Micro-break）与大休息（Long-break）双轨配置
    /// 是否启用微休息（默认开启）
    static let microBreakEnabled = "microBreakEnabled"
    /// 微休息触发间隔（分钟），推荐 15 分钟
    static let microBreakIntervalMinutes = "microBreakIntervalMinutes"
    /// 微休息持续时长（秒），推荐 15 秒（10~15 秒，含 2 秒闭眼泵压与重涂）
    static let microBreakDurationSeconds = "microBreakDurationSeconds"
    /// 是否启用大休息（与微休息双轨并行，默认开启）
    static let longBreakEnabled = "longBreakEnabled"

    // MARK: - 眨眼节律
    /// 是否启用眨眼提醒（默认开启）
    static let blinkReminderEnabled = "blinkReminderEnabled"
    /// 眨眼提醒间隔（分钟），推荐 5 分钟
    static let blinkIntervalMinutes = "blinkIntervalMinutes"
    /// 眨眼时是否同时点亮屏幕四周极淡的光晕（默认关闭，多数人光看菜单栏就够）
    static let blinkHaloEnabled = "blinkHaloEnabled"
}

// MARK: - 设置项属性包装器
//
// 消除「getter 判 nil 给默认值 + setter 直接写」的重复样板。
// 用法：
//   @BoolSetting(ConfigKeys.soundEnabled, default: true)  var soundEnabled: Bool

@propertyWrapper
struct BoolSetting {
    let key: String
    let defaultValue: Bool

    init(_ key: String, default defaultValue: Bool) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
            return UserDefaults.standard.bool(forKey: key)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct IntSetting {
    let key: String
    let defaultValue: Int

    init(_ key: String, default defaultValue: Int) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Int {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
            return UserDefaults.standard.integer(forKey: key)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct DoubleSetting {
    let key: String
    let defaultValue: Double

    init(_ key: String, default defaultValue: Double) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Double {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
            return UserDefaults.standard.double(forKey: key)
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - 视觉样式
//
// 这里的数值和 assets/render-breath.swift 用的是同一组 —— 改配色时两处都要改。
// （README 的「循环休息画面」一节里有对应说明）

enum Style {

    /// 背景径向渐变：中心 → 边缘
    enum Background {
        static let innerR: CGFloat = 0.078, innerG: CGFloat = 0.086, innerB: CGFloat = 0.118   // #14161E
        static let outerR: CGFloat = 0.014, outerG: CGFloat = 0.016, outerB: CGFloat = 0.028   // #040407
        /// 渐变中心（CALayer 左下原点坐标）
        static let centerY: CGFloat = 0.52
    }

    /// 冷青主色
    enum Accent {
        static let r: CGFloat = 0.42, g: CGFloat = 0.88, b: CGFloat = 0.80                     // #6BE0CC
    }

    /// 主文案与辅助文案颜色
    enum Text {
        static let titleR: CGFloat = 0.97, titleG: CGFloat = 0.98, titleB: CGFloat = 1.0
        static let subtitleR: CGFloat = 0.63, subtitleG: CGFloat = 0.67, subtitleB: CGFloat = 0.74
    }

    /// 光晕 / 内容中心在画面中的位置（距顶部的比例）
    static let glowCenterFromTop: CGFloat = 0.415
}
