import Cocoa

/// 眨眼节律提醒
///
/// 为什么不用弹窗 / 通知 / 声音：
/// 这个提醒每 5 分钟一次，一小时 12 次。任何「弹出来的东西」在第一次还有效，
/// 第三次就变成噪音 —— 要么被无视，要么更糟：把注意力从正在做的事上拽走，
/// 反而让人更频繁地忘记眨眼。
///
/// 所以这里走的是「周边视觉」通道，三个层次，一个比一个轻：
///
///  1. **菜单栏图标眨眼**（主通道）
///     图标本来就在视线上方边缘，一次 0.8 秒的闭眼动画能直接诱发镜像性眨眼
///     反射 —— 看到「眼睛闭上」自己也会眨，这比读一行「请眨眼」的文字快得多，
///     而且完全不占用认知资源。
///
///  2. **图标缓慢变干**（过程提示）
///     两次眨眼之间，图标按距离下次的进度逐渐变淡，最多降到 60%。
///     于是图标本身成了进度条：越淡 = 眼睛越干。余光扫到就会下意识眨一下，
///     不需要任何弹窗来"提醒"。
///
///  3. **屏幕边缘极淡呼吸**（可选，默认关）
///     只在最外圈 130pt 内做一圈峰值 5% 的提亮，3 秒淡入淡出。
///     中心内容一像素都不遮挡，周边视觉能捕捉到，但不会把视线拉走。
///     全屏窗口 + 鼠标穿透 + 不成为 key window，不打断任何输入。
final class BlinkReminder {

    // MARK: - 外部依赖

    /// 由 AppDelegate 提供当前的菜单栏按钮；眨眼动画直接改它的 image / alpha
    var buttonProvider: (() -> NSStatusBarButton?)?
    /// 动画播放结束后回调，让 AppDelegate 重建正常图标
    var didFinishBlink: (() -> Void)?

    // MARK: - 状态

    private(set) var isAnimating = false
    private var secondsSinceBlink: TimeInterval = 0
    private var lastDimUpdate: TimeInterval = 0
    private var animTimer: Timer?
    private var haloWindows: [NSWindow] = []
    private var haloView: BlinkHaloView?
    private var haloStart: CFTimeInterval = 0
    private var haloDisplayTimer: Timer?

    /// 动画共 0.8 秒，每 0.04 秒一帧
    private let frameInterval: TimeInterval = 0.04
    private let totalFrames = 20

    // MARK: - 配置

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: ConfigKeys.blinkReminderEnabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: ConfigKeys.blinkReminderEnabled)
            if !newValue { reset(restoreIcon: true) }
        }
    }

    var intervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: ConfigKeys.blinkIntervalMinutes)
            return v > 0 ? v : 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: ConfigKeys.blinkIntervalMinutes)
            reset(restoreIcon: true)
        }
    }

    var haloEnabled: Bool {
        get { UserDefaults.standard.object(forKey: ConfigKeys.blinkHaloEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: ConfigKeys.blinkHaloEnabled) }
    }

    private var intervalSeconds: TimeInterval { TimeInterval(intervalMinutes * 60) }

    /// 距离下次眨眼还有多久（秒），供菜单展示
    var secondsUntilNext: TimeInterval {
        max(0, intervalSeconds - secondsSinceBlink)
    }

    // MARK: - 主循环
    //
    // 由 AppDelegate 每秒调用一次。只有「眼睛确实在看屏幕」时才累计：
    // 走开、锁屏、正在休息时全部冻结，回来接着算 —— 不然上个厕所回来
    // 第一秒就催你眨眼，毫无意义。

    func tick(active: Bool) {
        guard isEnabled, active, !isAnimating else { return }

        secondsSinceBlink += 1

        if secondsSinceBlink >= intervalSeconds {
            fire()
            return
        }

        // 变淡每 3 秒更新一次就够，没必要每秒重绘菜单栏
        if secondsSinceBlink - lastDimUpdate >= 3 {
            lastDimUpdate = secondsSinceBlink
            updateDimming()
        }
    }

    /// 从「该眨眼了」开始，图标逐渐变干。最后 30% 才明显，前面保持全亮。
    private func updateDimming() {
        guard let button = buttonProvider?(), !isAnimating else { return }
        let progress = min(1, secondsSinceBlink / intervalSeconds)
        // 0% ~ 70% 不动；70% → 100% 之间从 1.0 线性降到 0.6
        let dimStart = 0.70
        let alpha: CGFloat
        if progress <= dimStart {
            alpha = 1.0
        } else {
            let t = (progress - dimStart) / (1 - dimStart)
            alpha = 1.0 - 0.4 * t
        }
        button.alphaValue = alpha
    }

    // MARK: - 触发

    /// 走完一轮：眨眼动画 + 可选边缘光晕，然后重新计时
    func fire(manual: Bool = false) {
        guard !isAnimating else { return }
        secondsSinceBlink = 0
        lastDimUpdate = 0
        animateBlink()
        if haloEnabled { playHalo() }
        logDebug("眨眼节律：\(manual ? "手动演示" : "到点提醒")，间隔 \(intervalMinutes) 分钟")
    }

    // MARK: - 菜单栏眨眼动画

    private func animateBlink() {
        guard let button = buttonProvider?() else { return }
        isAnimating = true
        button.alphaValue = 1.0

        let open = symbol("eye.fill")
        let closed = symbol("eye.half.closed.fill")
        var frame = 0

        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { [weak self] t in
            guard let self = self, let button = self.buttonProvider?() else {
                t.invalidate()
                return
            }
            frame += 1

            // 时间轴（20 帧 × 40ms = 800ms）
            //   0–5    睁眼，保持
            //   6–8    快速闭合
            //   9–11   闭住（最暗）
            //   12–15  睁开
            //   16–19  恢复
            switch frame {
            case 0...5:
                button.image = open
                button.alphaValue = 1.0
            case 6...8:
                button.image = closed
                button.alphaValue = 0.55
            case 9...11:
                button.image = closed
                button.alphaValue = 0.30
            case 12...15:
                button.image = open
                button.alphaValue = 0.85
            default:
                button.image = open
                button.alphaValue = 1.0
            }

            if frame >= self.totalFrames {
                t.invalidate()
                self.animTimer = nil
                self.isAnimating = false
                button.alphaValue = 1.0
                self.didFinishBlink?()
            }
        }
        if let timer = animTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }

    /// 仅演示边缘光晕（不动菜单栏图标），用于调视觉效果 / 判断要不要开
    func previewHalo() {
        playHalo()
    }

    // MARK: - 边缘光晕
    //
    // 全屏、透明、鼠标穿透、不成为 key。只在最外圈做提亮，
    // 中心区域完全不绘制，所以不会遮挡任何内容。

    private func playHalo() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        haloWindows.forEach { $0.orderOut(nil) }
        haloWindows.removeAll()

        for screen in screens {
            let w = NSWindow(contentRect: screen.frame,
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = BlinkHaloView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFront(nil)
            haloWindows.append(w)
            if haloView == nil { haloView = v }
        }

        // 3 秒：1.2s 淡入 → 0.6s 保持 → 1.2s 淡出
        haloStart = CACurrentMediaTime()
        haloDisplayTimer?.invalidate()
        haloDisplayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.haloStart
            let duration = 3.0
            if elapsed >= duration {
                t.invalidate()
                self.haloDisplayTimer = nil
                self.haloWindows.forEach { $0.orderOut(nil) }
                self.haloWindows.removeAll()
                self.haloView = nil
                return
            }
            let peak: CGFloat = 0.075
            let v: CGFloat
            if elapsed < 1.2 {
                v = peak * CGFloat(elapsed / 1.2)
            } else if elapsed < 1.8 {
                v = peak
            } else {
                v = peak * CGFloat(1 - (elapsed - 1.8) / 1.2)
            }
            self.haloWindows.compactMap { $0.contentView as? BlinkHaloView }
                .forEach { $0.intensity = v }
        }
        if let t = haloDisplayTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // MARK: - 重置

    func reset(restoreIcon: Bool) {
        secondsSinceBlink = 0
        lastDimUpdate = 0
        animTimer?.invalidate()
        animTimer = nil
        isAnimating = false
        haloDisplayTimer?.invalidate()
        haloDisplayTimer = nil
        haloWindows.forEach { $0.orderOut(nil) }
        haloWindows.removeAll()
        if restoreIcon {
            buttonProvider?()?.alphaValue = 1.0
            didFinishBlink?()
        }
    }
}

// MARK: - 光晕视图

/// 只在四周画一圈向内衰减的提亮，中间一律不画。
final class BlinkHaloView: NSView {

    var intensity: CGFloat = 0 {
        didSet { if abs(oldValue - intensity) > 0.0005 { needsDisplay = true } }
    }

    /// 光带宽度（点）
    private let band: CGFloat = 110

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard intensity > 0.0005 else { return }
        let b = bounds
        let top = NSRect(x: 0, y: b.height - band, width: b.width, height: band)
        let bottom = NSRect(x: 0, y: 0, width: b.width, height: band)
        let left = NSRect(x: 0, y: 0, width: band, height: b.height)
        let right = NSRect(x: b.width - band, y: 0, width: band, height: b.height)

        // 用主色而不是白色：白色"提亮"在白底网页上等于隐形（实测纯白区域
        // 叠加 5% 白后亮度 254.8→255，肉眼完全看不出）。改用主色的淡青，
        // 白底上表现为极轻的色偏，深底上仍是一圈微光，两种界面都成立。
        let accent = NSColor(srgbRed: Style.Accent.r,
                             green: Style.Accent.g,
                             blue: Style.Accent.b,
                             alpha: 1)
        let edge = accent.withAlphaComponent(intensity)
        let clear = accent.withAlphaComponent(0)

        // angle: 0 = 左→右，90 = 下→上
        NSGradient(starting: edge, ending: clear)?.draw(in: top, angle: -90)
        NSGradient(starting: edge, ending: clear)?.draw(in: bottom, angle: 90)
        NSGradient(starting: edge, ending: clear)?.draw(in: left, angle: 0)
        NSGradient(starting: edge, ending: clear)?.draw(in: right, angle: 180)
    }
}
