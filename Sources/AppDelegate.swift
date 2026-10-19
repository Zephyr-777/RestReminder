import Cocoa
import AVFoundation

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    
    // Time tracking (in seconds)
    var activeSeconds: Int = 0
    var isManualPaused: Bool = false
    var isReminding: Bool = false
    
    // Thresholds:
    // 无输入超过这个时长、且屏幕没有任何活动迹象，才判定为离开。
    // 默认 5 分钟（旧版是 3 分钟，太容易在看视频/读文档时误判）。
    static let defaultAwayThreshold: Double = 300.0
    // 无输入且屏幕一直亮着超过 15 分钟 —— 兜底认定「确实休息过了」，清空计时。
    // 正常情况下用不到它：真离开时显示器会先休眠，走的是屏幕休眠那条路径。
    let restThresholdSeconds: Double = 900.0

    // 当前在场判定
    var presence: Presence = .focusing
    // 断言检测有成本，2 秒刷新一次就够（IOKit 调用本身很快，这里只是别浪费）
    var mediaPlaying: Bool = false
    var lastAssertionCheck: Date = .distantPast

    var lastIdleTime: Double = 0.0
    // 记录状态栏图标当前对应的状态，避免每秒重复重建图标
    var lastIconState: String = ""

    /// 眨眼节律提醒（5 分钟一次的轻提醒，不抢焦点）
    let blinkReminder = BlinkReminder()
    
    // MARK: 设置项
    // 用 propertyWrapper 消除「getter 判 nil 给默认值 + setter 直接写」的样板。
    // 改默认值只改这里；set 行为（菜单里改时长）由包装器统一接管。

    // ── 微休息（Micro-break）设置
    @BoolSetting(ConfigKeys.microBreakEnabled, default: true)
    var microBreakEnabled: Bool
    @IntSetting(ConfigKeys.microBreakIntervalMinutes, default: 15)
    var microBreakIntervalMinutes: Int
    @IntSetting(ConfigKeys.microBreakDurationSeconds, default: 15)
    var microBreakDurationSeconds: Int

    // ── 大休息（Long-break）设置
    // 双轨默认全开：微休息与45分钟大休息同时生效，不再分级
    @BoolSetting(ConfigKeys.longBreakEnabled, default: true)
    var longBreakEnabled: Bool

    @IntSetting(ConfigKeys.targetMinutes, default: 45)         var targetMinutes: Int
    @BoolSetting(ConfigKeys.soundEnabled, default: true)       var soundEnabled: Bool
    @BoolSetting(ConfigKeys.voiceEnabled, default: true)       var voiceEnabled: Bool

    /// 到点强制熄屏（默认关，避免上来就吓人一跳）
    @BoolSetting(ConfigKeys.forceSleepEnabled, default: false) var forceSleepEnabled: Bool

    /// 提醒动画播完后是否落进循环休息画面（伪熄屏）。
    /// 默认开启；影片缺失时会自动退回原来的「真熄屏」行为。
    @BoolSetting(ConfigKeys.loopVideoEnabled, default: true)   var loopVideoEnabled: Bool

    /// 循环休息画面的倒计时时长（分钟）。0 = 不限时，只能手动结束
    @IntSetting(ConfigKeys.restCountdownMinutes, default: 5)   var restCountdownMinutes: Int

    /// 熄屏前全屏提醒停留的秒数
    @IntSetting(ConfigKeys.forceSleepLeadSeconds, default: 8)  var sleepLeadSeconds: Int

    /// 无输入多久算离开（秒）。存的是 Int，对外提供 Double，
    /// 所以带一层自定义转换，不能只用一行声明。
    @IntSetting(ConfigKeys.awayThresholdSeconds, default: Int(AppDelegate.defaultAwayThreshold))
    private var awayThresholdStored: Int
    var awayThresholdSeconds: Double {
        get { Double(awayThresholdStored) }
        set { awayThresholdStored = Int(newValue) }
    }
    
    // 微休息走表累积与全屏引导
    var microBreakActiveSeconds: Int = 0
    var microOverlay: MicroBreakOverlay?
    var isInMicroBreak: Bool = false

    // 当前显示中的大休息全屏遮罩
    var overlay: BreakOverlay?
    // 熄屏后等用户回来，自动重新计时
    var pendingResetAfterSleep: Bool = false
    // 是否正处在「循环休息画面」里（伪熄屏：屏幕没黑，在播呼吸光晕）
    var inRestLoop: Bool = false
    // 循环中「用户回来了」的连续计数。连续 2 秒才认，避免一下误触就退出
    var restLoopResumeTicks: Int = 0
    // 这次循环是不是从「预览」进来的。预览不该影响真实计时，退出时不清零
    var restLoopIsPreview: Bool = false
    
    // UI Outlets
    var statusMenuItem: NSMenuItem!
    var healthTipMenuItem: NSMenuItem!
    var presenceDetailItem: NSMenuItem!
    var pauseMenuItem: NSMenuItem!

    // 微休息设置
    var microBreakToggleItem: NSMenuItem!
    var microInterval10Item: NSMenuItem!
    var microInterval15Item: NSMenuItem!
    var microInterval20Item: NSMenuItem!
    var microDuration10Item: NSMenuItem!
    var microDuration15Item: NSMenuItem!
    var microDuration20Item: NSMenuItem!

    // 大休息设置
    var longBreakToggleItem: NSMenuItem!
    var duration40Item: NSMenuItem!
    var duration45Item: NSMenuItem!
    var duration50Item: NSMenuItem!
    var forceSleepToggleItem: NSMenuItem!
    var loopVideoToggleItem: NSMenuItem!
    var restCountdownItems: [NSMenuItem] = []
    var sleepLead5Item: NSMenuItem!
    var sleepLead8Item: NSMenuItem!
    var sleepLead15Item: NSMenuItem!

    // 系统通用项
    var soundToggleItem: NSMenuItem!
    var voiceToggleItem: NSMenuItem!
    var autostartToggleItem: NSMenuItem!
    var awayThresholdItems: [NSMenuItem] = []

    // 眨眼节律菜单
    var blinkToggleItem: NSMenuItem!
    var blinkIntervalItems: [NSMenuItem] = []
    var blinkHaloItem: NSMenuItem!
    var blinkStatusItem: NSMenuItem!

    // 用眼报告菜单
    var reportHeadlineItem: NSMenuItem!

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前把统计落盘，避免节流窗口里丢最后十几秒
        Stats.shared.flush(force: true)
        logDebug("applicationWillTerminate: 统计已落盘")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logDebug("applicationDidFinishLaunching start")
        setupStatusItem()
        setupMenu()

        // 眨眼提醒寄生在菜单栏图标上：直接改 button 的 image / alpha，
        // 播完再回调 updateStatusIcon 把正常图标装回去。
        blinkReminder.buttonProvider = { [weak self] in self?.statusItem.button }
        blinkReminder.didFinishBlink = { [weak self] in
            guard let self = self else { return }
            // 清掉状态缓存，强制按当前在场状态重建一次图标
            self.lastIconState = ""
            self.updateStatusIcon()
        }

        startTimer()
        
        // 等布局完成后再打日志。0.5s 时窗口还没被系统定位，会误报 (0, -22)。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            let win = self.statusItem.button?.window
            let f = win?.frame ?? .zero
            logDebug("StatusItem ready: win=(\(f.origin.x),\(f.origin.y) \(f.width)x\(f.height)) screen=\(String(describing: win?.screen?.localizedName)) isVisible=\(self.statusItem.isVisible)")
        }
        
        let launchScript = """
        display notification "休息提醒已在右上角状态栏就绪 👁" with title "休息提醒 ☕️" sound name "Glass"
        """
        runAppleScript(launchScript)
    }
    
    // 当用户再次双击 App 或在终端 open 时，主动弹出菜单
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logDebug("applicationShouldHandleReopen triggered")
        if let button = statusItem.button {
            statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
        return true
    }
    
    // MARK: - Status Item Setup
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }
    
    func updateStatusIcon() {
        guard let button = statusItem.button else {
            logDebug("Error: statusItem.button is nil")
            return
        }

        // 眨眼动画正在逐帧改这个 button，别跟它抢（动画结束会回调本方法）
        if blinkReminder.isAnimating { return }

        // 暂停判定直接读在场状态，不再靠空闲秒数反推
        let isAway: Bool
        if isManualPaused {
            isAway = true
        } else if case .away = presence {
            isAway = true
        } else {
            isAway = false
        }

        // 眼睛图标：
        //   微休息中 = eye.circle.fill                     圆环眼睛，轻柔微休
        //   大休息中 = eye.trianglebadge.exclamationmark.fill 警告三角，深度休息
        //   离开中   = eye.half.closed.fill                半闭眼，暂停计时
        //   专注中   = eye.fill                            睁眼，正常计时
        let stateKey: String
        if isInMicroBreak {
            stateKey = "micro_resting"
        } else if isReminding {
            stateKey = "resting"
        } else if isAway {
            stateKey = "away"
        } else {
            stateKey = "focus"
        }

        // 状态没变就不重建图标，省掉每秒一次的图像创建
        guard stateKey != lastIconState else { return }

        let symbolName: String
        let accessibilityText: String
        switch stateKey {
        case "micro_resting":
            symbolName = "eye.circle.fill"
            accessibilityText = "微休息中 · 泪膜重涂"
        case "resting":
            symbolName = "eye.trianglebadge.exclamationmark.fill"
            accessibilityText = "大休息中 · 眺望远方"
        case "away":
            symbolName = "eye.half.closed.fill"
            accessibilityText = "已暂停计时"
        default:
            symbolName = "eye.fill"
            accessibilityText = "护眼计时中"
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityText)?
            .withSymbolConfiguration(symbolConfig) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = accessibilityText
            lastIconState = stateKey
        } else {
            // 兜底：万一符号加载失败，退回 emoji，保证图标不会整个消失
            button.image = nil
            button.title = isInMicroBreak ? "🌱" : (isReminding ? "☕️" : (isAway ? "💤" : "🚶"))
        }
    }

    // MARK: - Menu Setup
    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        
        statusMenuItem = NSMenuItem(title: "⏱️ 正在检测状态...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        healthTipMenuItem = NSMenuItem(title: "👀 护眼法则: 闭紧双眼2秒重涂泪膜 · 远眺6米松睫状肌", action: nil, keyEquivalent: "")
        healthTipMenuItem.isEnabled = false
        menu.addItem(healthTipMenuItem)

        // 判定依据实时摊开显示
        presenceDetailItem = NSMenuItem(title: "📡 信号读取中...", action: nil, keyEquivalent: "")
        presenceDetailItem.isEnabled = false
        menu.addItem(presenceDetailItem)
        
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem.separator())

        let resetItem = NSMenuItem(title: "🔄 重新计时 / 我已休息", action: #selector(resetTimerAction), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)
        
        pauseMenuItem = NSMenuItem(title: "⏸️ 暂停提醒", action: #selector(togglePauseAction), keyEquivalent: "p")
        pauseMenuItem.target = self
        menu.addItem(pauseMenuItem)
        
        menu.addItem(NSMenuItem.separator())

        // ── 子菜单 1：微休息设置 (Micro-break)
        let microSubmenu = NSMenu()
        microBreakToggleItem = NSMenuItem(title: "🌱 启用微休息 (Micro-break)", action: #selector(toggleMicroBreakAction), keyEquivalent: "")
        microBreakToggleItem.target = self
        microSubmenu.addItem(microBreakToggleItem)
        microSubmenu.addItem(NSMenuItem.separator())

        let microIntervalParent = NSMenuItem(title: "⏱️ 触发间隔", action: nil, keyEquivalent: "")
        let microIntervalSubmenu = NSMenu()
        microInterval10Item = NSMenuItem(title: "10 分钟", action: #selector(setMicroIntervalAction(_:)), keyEquivalent: "")
        microInterval10Item.tag = 10
        microInterval10Item.target = self
        microIntervalSubmenu.addItem(microInterval10Item)

        microInterval15Item = NSMenuItem(title: "15 分钟 (临床推荐)", action: #selector(setMicroIntervalAction(_:)), keyEquivalent: "")
        microInterval15Item.tag = 15
        microInterval15Item.target = self
        microIntervalSubmenu.addItem(microInterval15Item)

        microInterval20Item = NSMenuItem(title: "20 分钟 (20-20-20 法则)", action: #selector(setMicroIntervalAction(_:)), keyEquivalent: "")
        microInterval20Item.tag = 20
        microInterval20Item.target = self
        microIntervalSubmenu.addItem(microInterval20Item)
        microIntervalParent.submenu = microIntervalSubmenu
        microSubmenu.addItem(microIntervalParent)

        let microDurationParent = NSMenuItem(title: "⏳ 休息时长", action: nil, keyEquivalent: "")
        let microDurationSubmenu = NSMenu()
        microDuration10Item = NSMenuItem(title: "10 秒", action: #selector(setMicroDurationAction(_:)), keyEquivalent: "")
        microDuration10Item.tag = 10
        microDuration10Item.target = self
        microDurationSubmenu.addItem(microDuration10Item)

        microDuration15Item = NSMenuItem(title: "15 秒 (推荐·泪膜重涂操)", action: #selector(setMicroDurationAction(_:)), keyEquivalent: "")
        microDuration15Item.tag = 15
        microDuration15Item.target = self
        microDurationSubmenu.addItem(microDuration15Item)

        microDuration20Item = NSMenuItem(title: "20 秒", action: #selector(setMicroDurationAction(_:)), keyEquivalent: "")
        microDuration20Item.tag = 20
        microDuration20Item.target = self
        microDurationSubmenu.addItem(microDuration20Item)
        microDurationParent.submenu = microDurationSubmenu
        microSubmenu.addItem(microDurationParent)

        microSubmenu.addItem(NSMenuItem.separator())
        let microPreviewItem = NSMenuItem(title: "👁️ 预览微休息动画（15秒泪膜重涂操）", action: #selector(previewMicroBreakAction), keyEquivalent: "")
        microPreviewItem.target = self
        microSubmenu.addItem(microPreviewItem)

        let microParentItem = NSMenuItem(title: "🌱 微休息设置 (每15分 / 15秒)", action: nil, keyEquivalent: "")
        microParentItem.submenu = microSubmenu
        menu.addItem(microParentItem)

        // ── 子菜单 2：大休息设置 (Long-break)
        let longSubmenu = NSMenu()
        longBreakToggleItem = NSMenuItem(title: "☕️ 启用大休息 (Long break)", action: #selector(toggleLongBreakAction), keyEquivalent: "")
        longBreakToggleItem.target = self
        longSubmenu.addItem(longBreakToggleItem)
        longSubmenu.addItem(NSMenuItem.separator())

        let longIntervalParent = NSMenuItem(title: "⚙️ 提醒周期设置", action: nil, keyEquivalent: "")
        let durationSubmenu = NSMenu()
        duration40Item = NSMenuItem(title: "40 分钟", action: #selector(setDurationAction(_:)), keyEquivalent: "")
        duration40Item.tag = 40
        duration40Item.target = self
        durationSubmenu.addItem(duration40Item)
        
        duration45Item = NSMenuItem(title: "45 分钟 (默认推荐)", action: #selector(setDurationAction(_:)), keyEquivalent: "")
        duration45Item.tag = 45
        duration45Item.target = self
        durationSubmenu.addItem(duration45Item)
        
        duration50Item = NSMenuItem(title: "50 分钟", action: #selector(setDurationAction(_:)), keyEquivalent: "")
        duration50Item.tag = 50
        duration50Item.target = self
        durationSubmenu.addItem(duration50Item)
        longIntervalParent.submenu = durationSubmenu
        longSubmenu.addItem(longIntervalParent)

        let cdParentItem = NSMenuItem(title: "⏳ 休息时长（倒计时）", action: nil, keyEquivalent: "")
        let cdSubmenu = NSMenu()
        restCountdownItems = []
        for mins in [3, 5, 10, 0] {
            let title: String
            if mins == 0 {
                title = "不限时（手动结束）"
            } else if mins == 5 {
                title = "\(mins) 分钟（默认）"
            } else {
                title = "\(mins) 分钟"
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(setRestCountdownAction(_:)),
                                  keyEquivalent: "")
            item.tag = mins
            item.target = self
            cdSubmenu.addItem(item)
            restCountdownItems.append(item)
        }
        cdParentItem.submenu = cdSubmenu
        longSubmenu.addItem(cdParentItem)

        longSubmenu.addItem(NSMenuItem.separator())

        forceSleepToggleItem = NSMenuItem(title: "🖥️ 到点强制熄屏", action: #selector(toggleForceSleepAction), keyEquivalent: "")
        forceSleepToggleItem.target = self
        longSubmenu.addItem(forceSleepToggleItem)

        let hasLoopVideo = BreakOverlay.isLoopVideoAvailable
        loopVideoToggleItem = NSMenuItem(title: hasLoopVideo
                                            ? "🎬 循环休息画面（不熄屏）"
                                            : "🎬 循环休息画面（缺少影片文件）",
                                         action: #selector(toggleLoopVideoAction),
                                         keyEquivalent: "")
        loopVideoToggleItem.target = self
        loopVideoToggleItem.isEnabled = hasLoopVideo
        longSubmenu.addItem(loopVideoToggleItem)

        let sleepSubmenu = NSMenu()
        for seconds in [5, 8, 15] {
            let item = NSMenuItem(title: seconds == 8 ? "\(seconds) 秒（默认）" : "\(seconds) 秒",
                                  action: #selector(setSleepLeadAction(_:)),
                                  keyEquivalent: "")
            item.tag = seconds
            item.target = self
            sleepSubmenu.addItem(item)
            switch seconds {
            case 5: sleepLead5Item = item
            case 8: sleepLead8Item = item
            default: sleepLead15Item = item
            }
        }
        sleepSubmenu.addItem(NSMenuItem.separator())
        let previewLongItem = NSMenuItem(title: "🌙 预览大休息完整流程（含循环）", action: #selector(previewSleepOverlayAction), keyEquivalent: "")
        previewLongItem.target = self
        sleepSubmenu.addItem(previewLongItem)

        let sleepParentItem = NSMenuItem(title: "⏱️ 熄屏前提醒时长", action: nil, keyEquivalent: "")
        sleepParentItem.submenu = sleepSubmenu
        longSubmenu.addItem(sleepParentItem)

        let longParentItem = NSMenuItem(title: "☕️ 大休息设置 (每45分 / 5分钟)", action: nil, keyEquivalent: "")
        longParentItem.submenu = longSubmenu
        menu.addItem(longParentItem)

        // ── 眨眼节律
        let blinkSubmenu = NSMenu()

        blinkStatusItem = NSMenuItem(title: "距离下次眨眼 5:00", action: nil, keyEquivalent: "")
        blinkStatusItem.isEnabled = false
        blinkSubmenu.addItem(blinkStatusItem)
        blinkSubmenu.addItem(NSMenuItem.separator())

        blinkToggleItem = NSMenuItem(title: "启用眨眼提醒", action: #selector(toggleBlinkAction), keyEquivalent: "")
        blinkToggleItem.target = self
        blinkSubmenu.addItem(blinkToggleItem)

        let blinkIntervalSubmenu = NSMenu()
        blinkIntervalItems = []
        for minutes in [3, 5, 10, 20] {
            let label = minutes == 5 ? "\(minutes) 分钟（推荐）" : "\(minutes) 分钟"
            let item = NSMenuItem(title: label, action: #selector(setBlinkIntervalAction(_:)), keyEquivalent: "")
            item.tag = minutes
            item.target = self
            blinkIntervalSubmenu.addItem(item)
            blinkIntervalItems.append(item)
        }
        let blinkIntervalParent = NSMenuItem(title: "⏱️ 提醒间隔", action: nil, keyEquivalent: "")
        blinkIntervalParent.submenu = blinkIntervalSubmenu
        blinkSubmenu.addItem(blinkIntervalParent)

        blinkSubmenu.addItem(NSMenuItem.separator())

        blinkHaloItem = NSMenuItem(title: "🖼️ 屏幕边缘光晕（更明显）", action: #selector(toggleBlinkHaloAction), keyEquivalent: "")
        blinkHaloItem.target = self
        blinkSubmenu.addItem(blinkHaloItem)

        let blinkPreviewItem = NSMenuItem(title: "👁 演示一次眨眼", action: #selector(previewBlinkAction), keyEquivalent: "")
        blinkPreviewItem.target = self
        blinkSubmenu.addItem(blinkPreviewItem)

        blinkSubmenu.addItem(NSMenuItem.separator())
        let blinkHint = NSMenuItem(title: "不弹窗、不出声，只动菜单栏那只眼睛", action: nil, keyEquivalent: "")
        blinkHint.isEnabled = false
        blinkSubmenu.addItem(blinkHint)

        let blinkParentItem = NSMenuItem(title: "👁️ 眨眼节律 (每5分钟)", action: nil, keyEquivalent: "")
        blinkParentItem.submenu = blinkSubmenu
        menu.addItem(blinkParentItem)

        // 离开判定阈值：无输入多久算离开
        let awaySubmenu = NSMenu()
        awayThresholdItems = []
        for minutes in [3, 5, 8, 10] {
            let label = minutes == 5 ? "\(minutes) 分钟（默认）" : "\(minutes) 分钟"
            let item = NSMenuItem(title: label, action: #selector(setAwayThresholdAction(_:)), keyEquivalent: "")
            item.tag = minutes * 60
            item.target = self
            awaySubmenu.addItem(item)
            awayThresholdItems.append(item)
        }
        awaySubmenu.addItem(NSMenuItem.separator())
        let awayHint = NSMenuItem(title: "屏幕熄灭或锁屏时立即暂停", action: nil, keyEquivalent: "")
        awayHint.isEnabled = false
        awaySubmenu.addItem(awayHint)

        let awayParentItem = NSMenuItem(title: "🚶 离开判定 (无操作多久算离开)", action: nil, keyEquivalent: "")
        awayParentItem.submenu = awaySubmenu
        menu.addItem(awayParentItem)

        // ── 用眼报告入口
        // 只放一个入口，不做多级跳转：菜单打开时那行摘要就已经把今日数字带出来了，
        // 想看详情点一次即可，不用先点进子菜单才知道今天怎么样。
        reportHeadlineItem = NSMenuItem(title: "今日还没有用眼记录", action: nil, keyEquivalent: "")
        reportHeadlineItem.isEnabled = false

        let reportTodayItem = NSMenuItem(title: "打开今日报告", action: #selector(openTodayReportAction), keyEquivalent: "d")
        reportTodayItem.target = self

        let reportYesterdayItem = NSMenuItem(title: "打开昨日报告", action: #selector(openYesterdayReportAction), keyEquivalent: "")
        reportYesterdayItem.target = self

        let reportFolderItem = NSMenuItem(title: "在访达中显示报告文件夹", action: #selector(revealReportsFolderAction), keyEquivalent: "")
        reportFolderItem.target = self

        let reportSubmenu = NSMenu()
        reportSubmenu.addItem(reportHeadlineItem)
        reportSubmenu.addItem(NSMenuItem.separator())
        reportSubmenu.addItem(reportTodayItem)
        reportSubmenu.addItem(reportYesterdayItem)
        reportSubmenu.addItem(NSMenuItem.separator())
        reportSubmenu.addItem(reportFolderItem)

        let reportParentItem = NSMenuItem(title: "📊 用眼报告", action: nil, keyEquivalent: "")
        reportParentItem.submenu = reportSubmenu
        menu.addItem(reportParentItem)

        menu.addItem(NSMenuItem.separator())
        
        soundToggleItem = NSMenuItem(title: "🔊 提示音 (Glass)", action: #selector(toggleSoundAction), keyEquivalent: "")
        soundToggleItem.target = self
        menu.addItem(soundToggleItem)
        
        voiceToggleItem = NSMenuItem(title: "🗣️ 语音播报提醒", action: #selector(toggleVoiceAction), keyEquivalent: "")
        voiceToggleItem.target = self
        menu.addItem(voiceToggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let testReminderItem = NSMenuItem(title: "🔔 发送一次测试提醒", action: #selector(testReminderAction), keyEquivalent: "t")
        testReminderItem.target = self
        menu.addItem(testReminderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        autostartToggleItem = NSMenuItem(title: "🚀 开机自动启动", action: #selector(toggleAutostartAction), keyEquivalent: "")
        autostartToggleItem.target = self
        menu.addItem(autostartToggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "🚪 退出 RestReminder", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
        
        // 把菜单结构写进日志：菜单项少了一个 / 勾选不对时，看一眼日志就知道
        updateMenuStates()
        logDebug("菜单结构:\n" + menuDescription(menu))
    }
    
    /// 递归描述菜单树，用于日志
    func menuDescription(_ menu: NSMenu, indent: Int = 0) -> String {
        var lines: [String] = []
        let pad = String(repeating: "    ", count: indent)
        for item in menu.items {
            if item.isSeparatorItem {
                lines.append("\(pad)────────")
                continue
            }
            lines.append("\(pad)\(item.title)\(item.state == .on ? "  [✓]" : "")")
            if let sub = item.submenu {
                lines.append(menuDescription(sub, indent: indent + 1))
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate (Runs whenever menu is opened)
    func menuWillOpen(_ menu: NSMenu) {
        updateMenuStates()
    }

    func updateMenuStates() {
        let targetSec = targetMinutes * 60
        let remainSec = max(0, targetSec - activeSeconds)
        let activeMin = activeSeconds / 60
        let remainMin = (remainSec + 59) / 60

        // 打开菜单时顺手重算一次：保证显示的是此刻的真实判定，而不是上一次 tick 的缓存
        mediaPlaying = PresenceDetector.hasDisplaySleepAssertion()
        lastAssertionCheck = Date()
        if !isManualPaused {
            presence = evaluatePresence(idleSec: lastIdleTime)
        }

        if isInMicroBreak {
            statusMenuItem.title = "🌱 状态: 微休息中 · 眨眼重涂泪膜"
        } else if isReminding {
            statusMenuItem.title = "☕️ 状态: 该大休息啦！已连续用电脑 \(activeMin) 分钟"
        } else if isManualPaused {
            statusMenuItem.title = "⏸️ 状态: 手动已暂停"
        } else {
            let idleMin = Int(lastIdleTime) / 60
            let idleSec = Int(lastIdleTime) % 60
            switch presence {
            case .focusing:
                var descParts: [String] = []
                if microBreakEnabled {
                    let microRem = max(0, microBreakIntervalMinutes * 60 - microBreakActiveSeconds)
                    descParts.append("微休剩 \(microRem / 60)分\(microRem % 60)秒")
                } else {
                    descParts.append("微休未开")
                }
                if longBreakEnabled {
                    descParts.append("大休剩 \(remainMin)分")
                } else {
                    descParts.append("大休未开")
                }
                statusMenuItem.title = "🟢 专注中 · " + descParts.joined(separator: " · ")
            case .watching:
                statusMenuItem.title = "🎬 状态: 屏幕内容播放中·仍计时 (已用 \(activeMin)分)"
            case .away(let reason):
                statusMenuItem.title = "💤 状态: \(reason.rawValue)·已暂停 (\(idleMin)分\(idleSec)秒没操作)"
            }
        }

        healthTipMenuItem.title = "👀 护眼法则: 闭紧双眼2秒重涂泪膜 · 远眺6米松睫状肌"

        // 把判定依据摊开显示，方便确认「为什么这次没暂停 / 为什么暂停了」
        presenceDetailItem.title = "📡 无操作 \(Int(lastIdleTime) / 60)分\(Int(lastIdleTime) % 60)秒"
            + " · 屏幕\(PresenceDetector.isDisplayAsleep() ? "已熄灭" : "亮着")"
            + " · 媒体\(mediaPlaying ? "播放中" : "未播放")"
            + " · 判定\(presence == .watching ? "播放中仍计时" : (isAwayNow ? "已暂停" : "计时中"))"

        pauseMenuItem.title = isManualPaused ? "▶️ 恢复提醒" : "⏸️ 暂停提醒"

        // 微休息设置状态
        microBreakToggleItem.state = microBreakEnabled ? .on : .off
        microInterval10Item.state = microBreakIntervalMinutes == 10 ? .on : .off
        microInterval15Item.state = microBreakIntervalMinutes == 15 ? .on : .off
        microInterval20Item.state = microBreakIntervalMinutes == 20 ? .on : .off

        microDuration10Item.state = microBreakDurationSeconds == 10 ? .on : .off
        microDuration15Item.state = microBreakDurationSeconds == 15 ? .on : .off
        microDuration20Item.state = microBreakDurationSeconds == 20 ? .on : .off

        // 大休息设置状态
        longBreakToggleItem.state = longBreakEnabled ? .on : .off
        duration40Item.state = targetMinutes == 40 ? .on : .off
        duration45Item.state = targetMinutes == 45 ? .on : .off
        duration50Item.state = targetMinutes == 50 ? .on : .off
        
        soundToggleItem.state = soundEnabled ? .on : .off
        voiceToggleItem.state = voiceEnabled ? .on : .off
        autostartToggleItem.state = checkAutostartInstalled() ? .on : .off
        
        forceSleepToggleItem.state = forceSleepEnabled ? .on : .off
        loopVideoToggleItem.state = loopVideoEnabled ? .on : .off
        for item in restCountdownItems {
            item.state = item.tag == restCountdownMinutes ? .on : .off
        }
        sleepLead5Item.state = sleepLeadSeconds == 5 ? .on : .off
        sleepLead8Item.state = sleepLeadSeconds == 8 ? .on : .off
        sleepLead15Item.state = sleepLeadSeconds == 15 ? .on : .off

        for item in awayThresholdItems {
            item.state = abs(Double(item.tag) - awayThresholdSeconds) < 0.5 ? .on : .off
        }

        // 眨眼节律状态
        blinkToggleItem.state = blinkReminder.isEnabled ? .on : .off
        for item in blinkIntervalItems {
            item.state = item.tag == blinkReminder.intervalMinutes ? .on : .off
        }
        blinkHaloItem.state = blinkReminder.haloEnabled ? .on : .off
        if blinkReminder.isEnabled {
            let remain = Int(blinkReminder.secondsUntilNext.rounded())
            let m = remain / 60, s = remain % 60
            blinkStatusItem.title = "距离下次眨眼 \(m):\(String(format: "%02d", s))"
        } else {
            blinkStatusItem.title = "眨眼提醒已关闭"
        }

        refreshReportHeadline()
    }

    /// 当前是否处于「暂停计时」状态（手动暂停也算）
    var isAwayNow: Bool {
        if isManualPaused { return true }
        if case .away = presence { return true }
        return false
    }

    // MARK: - Core Timer Loop
    func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 采集系统信号，判断人现在到底在不在屏幕前用眼。
    ///
    /// 判定优先级从「证据强度」高的往下走：
    /// 屏幕熄灭 / 锁屏 > 有内容在播放 > 单纯的键鼠空闲时长。
    func evaluatePresence(idleSec: Double) -> Presence {
        // 1) 屏幕熄灭 / 锁屏 —— 最硬的「人不在」证据。
        //    顺带解决了一个老问题：这里用的就是用户自己在「系统设置」里配的熄屏时间，
        //    不必再由我们去猜「离开多久算离开」，比固定阈值准得多。
        //    注意顺序：macOS 自动熄屏时通常同时上锁，先判熄屏能让菜单显示成
        //    「屏幕已熄灭」而不是「屏幕已锁定」—— 前者才是真实发生的动作。
        if PresenceDetector.isDisplayAsleep() { return .away(reason: .screenOff) }
        if PresenceDetector.isScreenLocked() { return .away(reason: .locked) }

        // 2) 屏幕上有内容在播放（视频 / 演示 / 线上会议）。
        //    这类程序会持有「阻止显示器休眠」断言：鼠标虽然十几分钟没动，
        //    眼睛却一直盯着屏幕。旧版在此处判成「离开」并停止计时 —— 正是最该提醒时沉默。
        if mediaPlaying { return .watching }

        // 3) 兜底：长时间无输入、屏幕还亮着。
        //    超过 15 分钟认定确实休息过了，直接清空（应对「永不熄屏」的设置）。
        if idleSec >= restThresholdSeconds { return .away(reason: .rested) }
        if idleSec >= awayThresholdSeconds { return .away(reason: .noInput) }

        return .focusing
    }

    func tick() {
        let idleSec = PresenceDetector.getIdleSeconds()
        lastIdleTime = idleSec

        // 断言查询是同步 IOKit 调用，每 2 秒刷一次足够
        if Date().timeIntervalSince(lastAssertionCheck) >= 2.0 {
            mediaPlaying = PresenceDetector.hasDisplaySleepAssertion()
            lastAssertionCheck = Date()
        }

        // 调试入口：`touch /tmp/rr_preview_blink.flag` 立刻演示一次眨眼
        let blinkFlag = "/tmp/rr_preview_blink.flag"
        if FileManager.default.fileExists(atPath: blinkFlag) {
            try? FileManager.default.removeItem(atPath: blinkFlag)
            logDebug("调试：收到 /tmp/rr_preview_blink.flag，演示一次眨眼")
            blinkReminder.fire(manual: true)
        }

        // 调试入口：`touch /tmp/rr_preview_halo.flag` 单独演示边缘光晕
        let haloFlag = "/tmp/rr_preview_halo.flag"
        if FileManager.default.fileExists(atPath: haloFlag) {
            try? FileManager.default.removeItem(atPath: haloFlag)
            logDebug("调试：收到 /tmp/rr_preview_halo.flag，单独演示边缘光晕")
            blinkReminder.previewHalo()
        }

        // 调试入口：检测到 /tmp/rr_preview_micro.flag 触发微休息预览
        let microFlag = "/tmp/rr_preview_micro.flag"
        if FileManager.default.fileExists(atPath: microFlag) {
            try? FileManager.default.removeItem(atPath: microFlag)
            logDebug("调试：收到 /tmp/rr_preview_micro.flag，触发微休息全屏指引")
            presentMicroBreakOverlay()
            return
        }

        // 调试入口：`touch /tmp/rr_preview_report.flag` 生成并打开今日用眼报告
        let reportFlag = "/tmp/rr_preview_report.flag"
        if FileManager.default.fileExists(atPath: reportFlag) {
            try? FileManager.default.removeItem(atPath: reportFlag)
            logDebug("调试：收到 /tmp/rr_preview_report.flag，生成今日用眼报告")
            openTodayReportAction()
        }

        // 调试入口：`touch /tmp/rr_preview_menu.flag` 打开菜单并停留 2.5 秒，方便外部截图。
        // 菜单进入 tracking 模式会阻塞主线程，所以收起用的 Timer 必须注册到 .eventTracking，
        // 否则它要等菜单关掉之后才会触发，等于没用。
        let menuFlag = "/tmp/rr_preview_menu.flag"
        if FileManager.default.fileExists(atPath: menuFlag) {
            try? FileManager.default.removeItem(atPath: menuFlag)
            logDebug("调试：收到 /tmp/rr_preview_menu.flag，打开菜单等待截图")
            let closer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
                self?.statusItem.menu?.cancelTracking()
            }
            RunLoop.main.add(closer, forMode: .eventTracking)
            RunLoop.main.add(closer, forMode: .common)
            statusItem.button?.performClick(nil)
        }

        // 微休息全屏指引中
        if isInMicroBreak {
            updateStatusIcon()
            return
        }

        // ── 循环休息画面中（伪熄屏）
        // 屏幕从没黑过，所以不能沿用下面「等屏幕亮回来」那套判断，那条路永远不成立。
        // 改为看「用户是否持续有动作」：idle 连续 2 秒归零才算回来了。
        // 要连续计数是为了防误触 —— 系统杂散事件会让 idle 抖一下，单看一次就退出太灵敏。
        if inRestLoop {
            // 调试出口：`touch /tmp/rr_exitloop.flag` 直接结束休息。
            // 靠合成鼠标事件触发退出不稳定（CGEventPost 的权限时灵时不灵），
            // 验证退出动画时用这个标记文件才控得住时序。
            let exitFlag = "/tmp/rr_exitloop.flag"
            if FileManager.default.fileExists(atPath: exitFlag) {
                try? FileManager.default.removeItem(atPath: exitFlag)
                logDebug("调试：收到退出休息的指令")
                exitRestLoop()
                return
            }

            if idleSec < 1.0 {
                restLoopResumeTicks += 1
                if restLoopResumeTicks >= 2 {
                    exitRestLoop()
                }
            } else {
                restLoopResumeTicks = 0
            }
            updateStatusIcon()
            return
        }

        // 强制熄屏后：屏幕是黑的，用户不动鼠标就一直是「无输入」状态。
        // 一旦 idle 归零说明他动鼠标唤醒回来了 —— 那就当作已经休息过，重新开始计时，
        // 否则唤醒后 activeSeconds 仍是满的，会立刻再次触发提醒，陷入死循环。
        if pendingResetAfterSleep {
            // 退出等待的条件必须是「屏幕真的亮回来了 + 用户有操作」。
            // 只看 idle 会被熄屏瞬间的杂散事件骗到：实测过屏幕还黑着就连续清了好几次零。
            let screenBack = !PresenceDetector.isDisplayAsleep() && !PresenceDetector.isScreenLocked()
            if screenBack && idleSec < 3 {
                pendingResetAfterSleep = false
                activeSeconds = 0
                microBreakActiveSeconds = 0
                isReminding = false
                presence = .focusing
                Stats.shared.longBreakEnded(preview: false)
                logDebug("检测到已从熄屏唤醒，大休与微休计时自动重置")
                updateStatusIcon()
            }
            return
        }

        if isManualPaused {
            presence = .focusing
            Stats.shared.recordPaused()
            updateStatusIcon()
            return
        }

        // 判定当前是否在场；状态变了才写日志，避免刷屏
        let newPresence = evaluatePresence(idleSec: idleSec)
        if newPresence != presence {
            logDebug("在场判定: \(presence) → \(newPresence)"
                + "  [无输入 \(Int(idleSec))s · 媒体断言 \(mediaPlaying ? "有" : "无")"
                + " · 屏熄 \(PresenceDetector.isDisplayAsleep() ? "是" : "否")"
                + " · 锁屏 \(PresenceDetector.isScreenLocked() ? "是" : "否")]")
            presence = newPresence
            updateStatusIcon()
        }

        switch presence {
        case .away(let reason):
            switch reason {
            case .screenOff, .locked:
                // 屏幕熄灭是「走开」场景的共同终点：合盖、离开座位、下班。
                // 标记一下，等用户唤醒回来时把计时清零。
                if !pendingResetAfterSleep {
                    pendingResetAfterSleep = true
                    logDebug("\(reason.rawValue)，转入等待唤醒；唤醒后重新计时")
                }
            case .rested:
                if activeSeconds > 0 || microBreakActiveSeconds > 0 {
                    activeSeconds = 0
                    microBreakActiveSeconds = 0
                    isReminding = false
                    logDebug("长时间无操作且屏幕常亮，判定已休息，计时清零")
                }
            case .noInput:
                break   // 单纯的短暂走开，保留已累积时长，回来接着算
            }
            Stats.shared.recordAway()
            updateStatusIcon()
            return

        case .focusing, .watching:
            break   // 两种情况都算用眼，继续累加
        }

        if isReminding {
            updateStatusIcon()
            return
        }

        // 走到这里说明这一秒眼睛确实在看屏幕，记一笔
        Stats.shared.recordFocus()

        // 眨眼节律：同样只在看屏幕时累计
        blinkReminder.tick(active: true)

        if microBreakEnabled {
            microBreakActiveSeconds += 1
        }
        if longBreakEnabled {
            activeSeconds += 1
        }

        // 优先级 1：大休息（到点优先执行大休息，并连带重置微休息）
        if longBreakEnabled && activeSeconds >= targetMinutes * 60 {
            microBreakActiveSeconds = 0
            triggerReminder()
            return
        }

        // 优先级 2：微休息（15分钟一到，弹 10~15 秒微休息指引）
        if microBreakEnabled && microBreakActiveSeconds >= microBreakIntervalMinutes * 60 {
            microBreakActiveSeconds = 0
            presentMicroBreakOverlay()
            return
        }

        updateStatusIcon()
    }

    // MARK: - 微休息指引
    func presentMicroBreakOverlay() {
        guard microOverlay == nil else {
            logDebug("presentMicroBreakOverlay: 遮罩已在显示中，忽略本次")
            return
        }
        isInMicroBreak = true
        updateStatusIcon()

        if soundEnabled {
            NSSound(named: "Glass")?.play()
        }

        if voiceEnabled {
            DispatchQueue.global(qos: .background).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["请闭眼两秒，完成泪膜重涂"]
                try? process.run()
            }
        }

        let ov = MicroBreakOverlay(duration: TimeInterval(microBreakDurationSeconds))
        microOverlay = ov
        ov.onFinish = { [weak self] naturally in
            guard let self = self else { return }
            self.microOverlay = nil
            self.isInMicroBreak = false
            self.microBreakActiveSeconds = 0
            // 刚闭眼休息过，眨眼节律重新起算，别一回到屏幕就催
            self.blinkReminder.reset(restoreIcon: false)
            self.updateStatusIcon()
            Stats.shared.microBreakEnded(naturally: naturally)
            logDebug("微休息结束 (自然完成=\(naturally))")
        }
        ov.present()
        Stats.shared.microBreakStarted()
        logDebug("触发微休息全屏提醒，时长 \(microBreakDurationSeconds) 秒")
    }

    // MARK: - Reminder Trigger (大休息提醒)
    func triggerReminder() {
        isReminding = true
        Stats.shared.longBreakTriggered()
        updateStatusIcon()
        
        let minutes = targetMinutes
        let message = "您已连续使用 Mac 达到 \(minutes) 分钟，请眺望远方、起身喝水或活动活动身体！"
        
        let soundClause = soundEnabled ? " sound name \"Glass\"" : ""
        let script = "display notification \"" + message + "\" with title \"休息提醒 ☕️\" subtitle \"关爱眼睛与身体\"" + soundClause
        runAppleScript(script)
        
        if voiceEnabled {
            let voiceText = "主人，您已经连续工作\(minutes)分钟了，请休息一下眼睛，起来活动活动吧。"
            DispatchQueue.global(qos: .background).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = [voiceText]
                try? process.run()
            }
        }
        
        // 开了强制熄屏才放全屏动画 —— 没开的时候用户可能正在开会/演示，不要打扰
        if forceSleepEnabled {
            presentSleepOverlay(forceSleep: true)
        }
    }

    // MARK: - 强制熄屏
    /// 全屏提醒动画。forceSleep = true 时动画走完会强制熄屏。
    func presentSleepOverlay(forceSleep: Bool) {
        guard overlay == nil else {
            logDebug("presentSleepOverlay: 遮罩已在显示中，忽略本次")
            return
        }
        
        let ov = BreakOverlay(duration: TimeInterval(sleepLeadSeconds))
        overlay = ov
        ov.onFinish = { [weak self] naturally in
            guard let self = self else { return }

            guard naturally else {
                // 用户在动画播完前按了 Esc
                self.overlay?.dismiss(animated: true)
                self.overlay = nil
                logDebug("用户按 Esc 取消了熄屏")
                return
            }

            guard forceSleep else {
                // 预览模式：不真熄屏。影片可用就把完整流程走一遍，方便直接看循环效果；
                // 否则退回原来的「播完即退」。
                if self.loopVideoEnabled,
                   self.overlay?.enterRestLoop(countdownSeconds: self.restCountdownMinutes * 60) == true {
                    self.inRestLoop = true
                    self.restLoopResumeTicks = 0
                    self.restLoopIsPreview = true
                    logDebug("预览：进入循环休息画面（未熄屏，不影响计时）")
                } else {
                    self.overlay?.dismiss(animated: true)
                    self.overlay = nil
                    logDebug("预览动画播完（未熄屏）")
                }
                return
            }

            // 正式触发：优先落进循环休息画面（伪熄屏 —— 屏幕不黑，播呼吸光晕）。
            // 开关关掉、或影片文件缺失时 enterRestLoop() 返回 false，退回原来的真熄屏。
            if self.loopVideoEnabled,
               self.overlay?.enterRestLoop(countdownSeconds: self.restCountdownMinutes * 60) == true {
                self.inRestLoop = true
                self.restLoopResumeTicks = 0
                self.restLoopIsPreview = false
                Stats.shared.longBreakStarted()
                logDebug("进入循环休息画面（伪熄屏）")
            } else {
                Stats.shared.longBreakStarted()
                self.forceDisplaySleep()
                self.pendingResetAfterSleep = true
                // 等显示器真的睡着再收遮罩，免得唤醒瞬间还能瞥见它
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.overlay?.dismiss()
                    self?.overlay = nil
                }
            }
        }
        ov.onExitLoop = { [weak self] in
            self?.exitRestLoop()
        }
        ov.present()
        logDebug("presentSleepOverlay: forceSleep=\(forceSleep) duration=\(sleepLeadSeconds)s")
    }

    /// 结束循环休息画面：收遮罩 + 计时清零。
    /// 两条路都会走到这里 —— 用户按 Esc，或 tick() 检测到他连续有动作。
    func exitRestLoop() {
        guard inRestLoop else { return }
        inRestLoop = false
        restLoopResumeTicks = 0

        overlay?.dismiss(animated: true)
        overlay = nil

        if restLoopIsPreview {
            // 预览不算真的休息过，不要动真实计时
            restLoopIsPreview = false
            presence = .focusing
            Stats.shared.longBreakEnded(preview: true)
            logDebug("预览的循环休息画面结束（不影响计时）")
        } else {
            // 已经休息过了，重新开始计时。
            // 不清零的话 activeSeconds 还是满的，下一秒会立刻再弹一次提醒，陷入死循环。
            activeSeconds = 0
            microBreakActiveSeconds = 0
            isReminding = false
            presence = .focusing
            Stats.shared.longBreakEnded(preview: false)
            // 大休息结束，眼睛刚充分湿润过，眨眼节律从头算
            blinkReminder.reset(restoreIcon: false)
            logDebug("循环休息画面结束，大休息与微休息计时均清零")
        }
        updateStatusIcon()
    }

    /// 直接让显示器进入睡眠。pmset displaysleepnow 不需要 root，也不会锁屏 —— 
    /// 动一下鼠标就回来，所以「强制」是安全的。
    func forceDisplaySleep() {
        logDebug("forceDisplaySleep: 执行 pmset displaysleepnow")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        do {
            try p.run()
            p.waitUntilExit()
            logDebug("pmset displaysleepnow 退出码 = \(p.terminationStatus)")
        } catch {
            logDebug("forceDisplaySleep 失败: \(error)")
        }
    }

    func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }

    // MARK: - Actions
    @objc func resetTimerAction() {
        activeSeconds = 0
        microBreakActiveSeconds = 0
        isReminding = false
        isInMicroBreak = false
        pendingResetAfterSleep = false
        inRestLoop = false
        overlay?.dismiss(animated: true)
        overlay = nil
        microOverlay?.dismiss(animated: true)
        microOverlay = nil
        updateStatusIcon()
        updateMenuStates()
        logDebug("手动重置所有计时")
    }

    // MARK: - 微休息动作
    @objc func toggleMicroBreakAction() {
        microBreakEnabled.toggle()
        microBreakActiveSeconds = 0
        updateMenuStates()
        updateStatusIcon()
        logDebug("微休息开关: \(microBreakEnabled)")
    }

    @objc func setMicroIntervalAction(_ sender: NSMenuItem) {
        microBreakIntervalMinutes = sender.tag
        microBreakActiveSeconds = 0
        updateMenuStates()
        logDebug("微休息间隔设为 \(microBreakIntervalMinutes) 分钟")
    }

    @objc func setMicroDurationAction(_ sender: NSMenuItem) {
        microBreakDurationSeconds = sender.tag
        updateMenuStates()
        logDebug("微休息时长设为 \(microBreakDurationSeconds) 秒")
    }

    @objc func previewMicroBreakAction() {
        presentMicroBreakOverlay()
    }

    @objc func toggleLongBreakAction() {
        longBreakEnabled.toggle()
        activeSeconds = 0
        updateMenuStates()
        updateStatusIcon()
        logDebug("大休息开关: \(longBreakEnabled)")
    }

    // MARK: - 眨眼节律

    @objc func toggleBlinkAction() {
        blinkReminder.isEnabled.toggle()
        updateMenuStates()
        updateStatusIcon()
        logDebug("眨眼提醒开关: \(blinkReminder.isEnabled)")
    }

    @objc func setBlinkIntervalAction(_ sender: NSMenuItem) {
        blinkReminder.intervalMinutes = sender.tag
        updateMenuStates()
        logDebug("眨眼提醒间隔设为 \(blinkReminder.intervalMinutes) 分钟")
    }

    @objc func toggleBlinkHaloAction() {
        blinkReminder.haloEnabled.toggle()
        updateMenuStates()
        logDebug("眨眼边缘光晕: \(blinkReminder.haloEnabled)")
    }

    @objc func previewBlinkAction() {
        // 演示前先关掉菜单，否则光晕被菜单挡住一半，看不出效果
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.blinkReminder.fire(manual: true)
        }
    }

    // MARK: - 用眼报告

    private func reportDateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 播报脚本用的 Python。
    /// 脚本只用标准库，任何 3.9+ 都能跑；优先找 Homebrew 的，最后退回系统自带的。
    private func pythonInterpreter() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["RESTREMINDER_PYTHON"],
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    @objc func openTodayReportAction() {
        generateAndOpenReport(daysAgo: 0)
    }

    @objc func openYesterdayReportAction() {
        generateAndOpenReport(daysAgo: 1)
    }

    @objc func revealReportsFolderAction() {
        Paths.ensure(Paths.reportsDir)
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.reportsDir))
    }

    /// 菜单里那行「今日已用眼 …」摘要。菜单每次打开都会重算，所以数字总是当下这一刻的。
    private func refreshReportHeadline() {
        guard reportHeadlineItem != nil else { return }

        let path = Paths.statsDir + "/" + reportDateKey(Date()) + ".json"

        var screen = 0
        var micro = 0
        if let data = FileManager.default.contents(atPath: path),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            screen = obj["screenSeconds"] as? Int ?? 0
            micro = obj["microTriggered"] as? Int ?? 0
        }

        if screen <= 0 {
            reportHeadlineItem.title = "今日还没有用眼记录"
        } else {
            let h = screen / 3600
            let m = (screen % 3600) / 60
            let span = h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分钟"
            reportHeadlineItem.title = "今日已用眼 \(span) · 微休息 \(micro) 次"
        }
    }

    /// 后台跑 Python 生成 HTML，完成后再回主线程打开。
    /// 不在主线程跑是因为当天数据过期时脚本会顺带刷新屏幕使用时间，可能要几秒。
    private func generateAndOpenReport(daysAgo: Int) {
        let key = reportDateKey(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
        let htmlPath = Paths.reportsDir + "/\(key).html"
        let script = Paths.toolsDir + "/daily_report.py"

        Paths.ensure(Paths.reportsDir)

        guard FileManager.default.fileExists(atPath: script) else {
            logDebug("用眼报告失败：找不到脚本 \(script)")
            notifyReportError("缺少生成脚本，请重新运行 install.sh 安装 tools")
            return
        }

        logDebug("开始生成用眼报告 \(key)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: self.pythonInterpreter())
            process.arguments = [script, "--date", key]
            process.currentDirectoryURL = URL(fileURLWithPath: Paths.toolsDir)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            var failure: String?
            do {
                try process.run()
                // 先读到 EOF 再等退出，避免管道写满时互相卡死
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = String(data: out, encoding: .utf8) ?? ""
                    failure = "退出码 \(process.terminationStatus)："
                        + String(text.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                if let failure = failure {
                    logDebug("用眼报告生成失败：\(failure)")
                    self.notifyReportError(failure)
                    return
                }
                guard FileManager.default.fileExists(atPath: htmlPath) else {
                    logDebug("用眼报告生成失败：脚本未产出 \(htmlPath)")
                    self.notifyReportError("脚本没有产出报告文件")
                    return
                }
                logDebug("用眼报告已打开：\(htmlPath)")
                NSWorkspace.shared.open(URL(fileURLWithPath: htmlPath))
            }
        }
    }

    private func notifyReportError(_ message: String) {
        // 通知正文里的引号会截断 AppleScript 字符串，先转义
        let safe = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        runAppleScript("display notification \"\(safe)\" with title \"用眼报告生成失败\"")
    }

    @objc func togglePauseAction() {
        isManualPaused.toggle()
        updateStatusIcon()
        updateMenuStates()
    }

    @objc func setDurationAction(_ sender: NSMenuItem) {
        targetMinutes = sender.tag
        updateMenuStates()
    }

    @objc func setAwayThresholdAction(_ sender: NSMenuItem) {
        awayThresholdSeconds = Double(sender.tag)
        // 改完立刻重算一次，菜单里能马上看到判定结果变化
        presence = evaluatePresence(idleSec: lastIdleTime)
        updateMenuStates()
        updateStatusIcon()
        logDebug("离开判定阈值改为 \(sender.tag / 60) 分钟")
    }

    @objc func toggleSoundAction() {
        soundEnabled.toggle()
        updateMenuStates()
    }

    @objc func toggleVoiceAction() {
        voiceEnabled.toggle()
        updateMenuStates()
    }

    @objc func testReminderAction() {
        triggerReminder()
    }

    @objc func toggleForceSleepAction() {
        forceSleepEnabled.toggle()
        updateMenuStates()
        logDebug("强制熄屏开关: \(forceSleepEnabled)")
    }

    @objc func toggleLoopVideoAction() {
        loopVideoEnabled.toggle()
        updateMenuStates()
        logDebug("循环休息画面开关: \(loopVideoEnabled)（影片可用=\(BreakOverlay.isLoopVideoAvailable)）")
    }

    @objc func setRestCountdownAction(_ sender: NSMenuItem) {
        restCountdownMinutes = sender.tag
        updateMenuStates()
        logDebug("休息倒计时时长: \(restCountdownMinutes) 分钟")
    }

    @objc func setSleepLeadAction(_ sender: NSMenuItem) {
        sleepLeadSeconds = sender.tag
        updateMenuStates()
    }

    @objc func previewSleepOverlayAction() {
        presentSleepOverlay(forceSleep: false)
    }

    @objc func toggleAutostartAction() {
        let current = checkAutostartInstalled()
        if current {
            uninstallAutostart()
        } else {
            installAutostart()
        }
        updateMenuStates()
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Autostart (LaunchAgent)
    static let autostartLabel = "com.zephyr777.restreminder"

    var launchAgentPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(AppDelegate.autostartLabel).plist")
    }

    func checkAutostartInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    /// 真正调用 launchctl，返回退出码（0 表示成功）
    @discardableResult
    func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            logDebug("launchctl \(args.joined(separator: " ")) failed: \(error)")
            return -1
        }
    }

    func installAutostart() {
        let bundleURL = Bundle.main.bundleURL

        // 关键：必须用 `open -a` 启动 .app，让应用拿到完整的 GUI 会话。
        // 直接执行 Contents/MacOS/xxx 会被 launchd 当成后台守护进程，
        // 应用将没有窗口服务器会话，NSStatusItem 永远不会出现在菜单栏
        // （表现为 window.screen == nil、窗口 frame 停在 (0, -22)）。
        let programArguments: String
        if bundleURL.pathExtension == "app" {
            programArguments = """
                    <string>/usr/bin/open</string>
                    <string>-a</string>
                    <string>\(bundleURL.path)</string>
            """
        } else if let exe = Bundle.main.executableURL {
            programArguments = "        <string>\(exe.path)</string>"
        } else {
            logDebug("installAutostart: 无法确定可执行文件路径")
            return
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppDelegate.autostartLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(programArguments)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
        </dict>
        </plist>
        """

        let launchAgentsDir = launchAgentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try? plistContent.write(to: launchAgentPlistURL, atomically: true, encoding: .utf8)

        // 只写文件是不够的：必须 bootstrap 进 launchd，否则它只是一个躺着的 plist。
        // 先 bootout 清掉可能存在的旧注册，再 bootstrap。
        runLaunchctl(["bootout", "gui/\(getuid())/\(AppDelegate.autostartLabel)"])
        let code = runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentPlistURL.path])
        logDebug("installAutostart: bootstrap exit=\(code) plist=\(launchAgentPlistURL.path)")
    }

    func uninstallAutostart() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(AppDelegate.autostartLabel)"])
        try? FileManager.default.removeItem(at: launchAgentPlistURL)
    }
}
