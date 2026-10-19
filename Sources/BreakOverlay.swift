import Cocoa
import AVFoundation

/// 强制熄屏前的全屏提醒动画。
///
/// 时间轴（duration = 8s 时）：
///   0.00s  深色径向渐变背景淡入
///   0.08s  中央冷色光晕浮现，随后持续呼吸
///   0.18s  眼睛图标 spring 弹入
///   0.38s  「该休息眼睛了」自下浮起
///   0.55s  副标题浮起
///   0.85s  进度条开始线性走满剩余时间
///   8.00s  回调 onFinish(true)，由调用方执行熄屏
///
/// 中途按 Esc 立刻取消，回调 onFinish(false)，不熄屏。
final class BreakOverlay {

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var finishWork: DispatchWorkItem?
    private var finished = false

    // 背景层引用。进入循环休息画面时，除它之外的所有内容层
    //（光晕/图标/文案/进度条/提示）都要整体淡出，只留下背景 + 循环影片。
    private var bgLayer: CALayer?

    // 循环休息画面的播放器
    private var queuePlayer: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    /// 是否已进入循环休息画面
    private(set) var isLooping = false
    /// 循环中用户按 Esc 时的回调（此时 onFinish 已失效）
    var onExitLoop: (() -> Void)?

    // 休息倒计时
    private var countdownLayer: CATextLayer?
    private var countdownTimer: Timer?
    /// 倒计时截止时刻。
    /// 用「截止时间」而不是递减计数 —— Timer 每次触发都会晚几毫秒，误差会累积，
    /// 实测 60 秒的倒计时跑成了 73 秒。按截止时间重算就不会漂。
    private var countdownDeadline: Date?
    private var countdownLastShown: Int = -1
    private var countdownFinished = false

    /// 循环影片在 bundle 里的文件名
    static let loopVideoName = "rest-loop"
    /// 影片是否可用 —— 不存在就退回原来的真熄屏行为，不能崩
    static var isLoopVideoAvailable: Bool {
        Bundle.main.url(forResource: loopVideoName, withExtension: "mp4") != nil
    }

    /// 遮罩停留时长（秒），进度条在这段时间内走满
    let duration: TimeInterval
    /// 结束回调：true = 正常走完（应熄屏）；false = 被用户取消
    var onFinish: ((Bool) -> Void)?

    init(duration: TimeInterval) {
        self.duration = max(3.0, duration)
    }

    var isShowing: Bool { !windows.isEmpty }

    // MARK: - Present / Dismiss

    func present() {
        guard windows.isEmpty else { return }
        finished = false
        removeKeyMonitor()

        for (index, screen) in NSScreen.screens.enumerated() {
            let win = OverlayWindow(contentRect: screen.frame,
                                    styleMask: [.borderless],
                                    backing: .buffered,
                                    defer: false,
                                    screen: screen)
            // 比 .screenSaver(1000) 再高一档，免得通知横幅之类的浮层压住提醒；
            // 又远低于 CGShieldingWindowLevel，不会盖住系统级弹窗
            win.level = NSWindow.Level(rawValue: 1500)
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.isMovable = false
            win.animationBehavior = .none
            win.contentView?.wantsLayer = true
            if let content = win.contentView {
                // 只主屏放内容，其余屏幕纯遮罩，避免多头显示分散注意力
                buildLayers(in: content, withContent: index == 0)
            }
            win.orderFrontRegardless()
            windows.append(win)
        }

        // 抢焦点才能收到 Esc
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 {                 // Esc
                // 已经在循环休息画面里：onFinish 已经用掉了，交给 AppDelegate 走「结束休息」的完整流程
                if self.isLooping {
                    self.onExitLoop?()
                } else {
                    self.finish(naturally: false)
                }
                return nil
            }
            return event
        }

        let work = DispatchWorkItem { [weak self] in
            self?.finish(naturally: true)
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 收起遮罩、回到桌面。
    ///
    /// animated 版本刻意做得慢一些（0.8s），而且顺序很关键：
    ///   1. 先整窗淡出，同时内容轻微放大（像「散开」而不是「被关掉」）；
    ///   2. 播放器与图层在这 0.8 秒里**必须保持存活**，等淡完再拆。
    ///
    /// 反过来做（先 stopLoopVideo 再淡出）会让 AVPlayerLayer 立刻变黑，
    /// 露出纯背景色，淡出第一帧就「跳」一下 —— 这正是之前的毛病。
    func dismiss(animated: Bool = false) {
        removeKeyMonitor()
        finishWork?.cancel()
        finishWork = nil
        isLooping = false

        let wins = windows
        windows.removeAll()

        guard !wins.isEmpty else {
            stopCountdown()
            stopLoopVideo()
            bgLayer = nil
            return
        }

        guard animated else {
            wins.forEach { $0.orderOut(nil) }
            stopCountdown()
            stopLoopVideo()
            bgLayer = nil
            return
        }

        // 交给闭包持有。BreakOverlay 随后会被 AppDelegate 置 nil，
        // 不捕获的话播放器先被释放，画面会在淡出途中变黑。
        let player = queuePlayer
        let vLayer = videoLayer
        let cdLayer = countdownLayer
        countdownTimer?.invalidate()
        countdownTimer = nil
        queuePlayer = nil
        looper = nil
        videoLayer = nil
        countdownLayer = nil
        bgLayer = nil

        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

        // 内容整体轻微放大：光晕是「散开」出去的，而不是原地消失
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.8)
        CATransaction.setAnimationTimingFunction(curve)
        for win in wins {
            for layer in win.contentView?.layer?.sublayers ?? [] {
                layer.transform = CATransform3DMakeScale(1.05, 1.05, 1.0)
            }
        }
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.8
            ctx.timingFunction = curve
            wins.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            player?.pause()
            vLayer?.removeFromSuperlayer()
            cdLayer?.removeFromSuperlayer()
            wins.forEach { $0.orderOut(nil) }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func finish(naturally: Bool) {
        guard !finished else { return }
        finished = true
        let cb = onFinish
        onFinish = nil
        cb?(naturally)
    }

    // MARK: - Layer 构建

    private func buildLayers(in view: NSView, withContent: Bool) {
        guard let root = view.layer else { return }
        let w = view.bounds.width
        let h = view.bounds.height
        let scale = view.window?.backingScaleFactor ?? 2.0

        // 布局照「距顶部多少」来想，再换算成本层坐标（macOS 上 CALayer 原点在左下）
        func fromTop(_ offset: CGFloat) -> CGFloat { h - offset }

        // 背景：中心微亮的深色径向渐变
        let bg = CAGradientLayer()
        bg.type = .radial
        bg.frame = CGRect(x: 0, y: 0, width: w, height: h)
        bg.colors = [
            NSColor(srgbRed: Style.Background.innerR, green: Style.Background.innerG, blue: Style.Background.innerB, alpha: 1).cgColor,
            NSColor(srgbRed: Style.Background.outerR, green: Style.Background.outerG, blue: Style.Background.outerB, alpha: 1).cgColor
        ]
        bg.locations = [0, 1]
        bg.startPoint = CGPoint(x: 0.5, y: Style.Background.centerY)
        bg.endPoint = CGPoint(x: 1.15, y: 1.3)
        root.addSublayer(bg)
        bgLayer = bg          // 只有主屏（withContent == true）会走到这一步
        fadeIn(bg, delay: 0, duration: 0.5, rise: 0)

        guard withContent else { return }

        let iconCenter = CGPoint(x: w / 2, y: fromTop(h * Style.glowCenterFromTop))
        let titleCenter = CGPoint(x: w / 2, y: fromTop(h * 0.545))
        let subtitleCenter = CGPoint(x: w / 2, y: fromTop(h * 0.625))
        let barCenter = CGPoint(x: w / 2, y: fromTop(h * 0.775))

        // ── 光晕（外wrapper管入场，内层管呼吸，避免同一属性上两个动画打架）
        let glowWrap = CALayer()
        let glowSize: CGFloat = 720
        glowWrap.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glowWrap.position = iconCenter
        root.addSublayer(glowWrap)
        fadeIn(glowWrap, delay: 0.08, duration: 1.1, rise: 0)

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = glowWrap.bounds
        glow.colors = [
            NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.30).cgColor,
            NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.0).cgColor
        ]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glowWrap.addSublayer(glow)

        let glowBreathe = CABasicAnimation(keyPath: "opacity")
        glowBreathe.fromValue = 0.5
        glowBreathe.toValue = 1.0
        glowBreathe.duration = 2.6
        glowBreathe.autoreverses = true
        glowBreathe.repeatCount = .infinity
        glowBreathe.beginTime = CACurrentMediaTime() + 1.2
        glowBreathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(glowBreathe, forKey: "rr.breathe")
        glow.opacity = 1

        // ── 眼睛图标
        let iconWrap = CALayer()
        let iconWrapSize: CGFloat = 160
        iconWrap.bounds = CGRect(x: 0, y: 0, width: iconWrapSize, height: iconWrapSize)
        iconWrap.position = iconCenter
        root.addSublayer(iconWrap)

        if let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "该休息眼睛了") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 104, weight: .light)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let img = symbol.withSymbolConfiguration(cfg) {
                var proposed = CGRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
                    let iconLayer = CALayer()
                    iconLayer.bounds = CGRect(x: 0, y: 0, width: proposed.width, height: proposed.height)
                    iconLayer.position = CGPoint(x: iconWrapSize / 2, y: iconWrapSize / 2)
                    iconLayer.contents = cg
                    iconLayer.contentsScale = scale
                    iconLayer.contentsGravity = .resizeAspect
                    iconWrap.addSublayer(iconLayer)

                    let iconBreathe = CABasicAnimation(keyPath: "transform.scale")
                    iconBreathe.fromValue = 1.0
                    iconBreathe.toValue = 1.05
                    iconBreathe.duration = 2.6
                    iconBreathe.autoreverses = true
                    iconBreathe.repeatCount = .infinity
                    iconBreathe.beginTime = CACurrentMediaTime() + 1.2
                    iconBreathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    iconLayer.add(iconBreathe, forKey: "rr.breathe")
                }
            }
        }

        fadeIn(iconWrap, delay: 0.18, duration: 0.5, rise: 0)

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.68
        pop.toValue = 1.0
        pop.mass = 1.0
        pop.stiffness = 170
        pop.damping = 13
        pop.duration = pop.settlingDuration
        pop.beginTime = CACurrentMediaTime() + 0.18
        pop.fillMode = .backwards
        pop.isRemovedOnCompletion = false
        iconWrap.add(pop, forKey: "rr.popIn")
        iconWrap.transform = CATransform3DIdentity

        // ── 文案
        let titleLayer = textLayer(text: "该休息眼睛了",
                                   font: NSFont.systemFont(ofSize: 74, weight: .semibold),
                                   color: NSColor(srgbRed: Style.Text.titleR, green: Style.Text.titleG, blue: Style.Text.titleB, alpha: 1.0),
                                   kern: 5,
                                   width: w,
                                   center: titleCenter,
                                   lineHeight: 96,
                                   scale: scale)
        root.addSublayer(titleLayer)
        fadeIn(titleLayer, delay: 0.38, duration: 0.75, rise: 22)

        let subtitleLayer = textLayer(text: "看向 6 米以外，让睫状肌松开",
                                      font: NSFont.systemFont(ofSize: 25, weight: .regular),
                                      color: NSColor(srgbRed: Style.Text.subtitleR, green: Style.Text.subtitleG, blue: Style.Text.subtitleB, alpha: 1.0),
                                      kern: 2,
                                      width: w,
                                      center: subtitleCenter,
                                      lineHeight: 40,
                                      scale: scale)
        root.addSublayer(subtitleLayer)
        fadeIn(subtitleLayer, delay: 0.55, duration: 0.75, rise: 18)

        // ── 进度条：线性走满，走完即熄屏
        let barWidth: CGFloat = 320
        let barHeight: CGFloat = 4
        let barStart: TimeInterval = 0.85
        let barDuration = max(0.6, duration - barStart)

        let track = CALayer()
        track.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        track.position = barCenter
        track.cornerRadius = barHeight / 2
        track.backgroundColor = NSColor(white: 1.0, alpha: 0.13).cgColor
        root.addSublayer(track)
        fadeIn(track, delay: 0.6, duration: 0.6, rise: 0)

        let fill = CALayer()
        fill.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.position = CGPoint(x: barCenter.x - barWidth / 2, y: barCenter.y)
        fill.cornerRadius = barHeight / 2
        fill.backgroundColor = NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 1.0).cgColor
        fill.opacity = 0
        root.addSublayer(fill)

        let grow = CABasicAnimation(keyPath: "transform.scale.x")
        grow.fromValue = 0.001
        grow.toValue = 1.0
        grow.duration = barDuration
        grow.beginTime = CACurrentMediaTime() + barStart
        grow.fillMode = .backwards
        grow.isRemovedOnCompletion = false
        grow.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(grow, forKey: "rr.progress")
        fill.transform = CATransform3DIdentity

        let fillFade = CABasicAnimation(keyPath: "opacity")
        fillFade.fromValue = 0
        fillFade.toValue = 1
        fillFade.duration = 0.5
        fillFade.beginTime = CACurrentMediaTime() + 0.6
        fillFade.fillMode = .backwards
        fillFade.isRemovedOnCompletion = false
        fill.add(fillFade, forKey: "rr.fillFadeIn")
        fill.opacity = 1

        // ── 底部退路提示
        let hintLayer = textLayer(text: "按 Esc 取消熄屏",
                                  font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                                  color: NSColor(white: 1.0, alpha: 0.34),
                                  kern: 2,
                                  width: w,
                                  center: CGPoint(x: w / 2, y: fromTop(h * 0.885)),
                                  lineHeight: 20,
                                  scale: scale)
        root.addSublayer(hintLayer)
        fadeIn(hintLayer, delay: 0.9, duration: 0.8, rise: 0)
    }

    private func textLayer(text: String,
                           font: NSFont,
                           color: NSColor,
                           kern: CGFloat,
                           width: CGFloat,
                           center: CGPoint,
                           lineHeight: CGFloat,
                           scale: CGFloat) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = scale
        layer.alignmentMode = .center
        layer.truncationMode = .none
        layer.isWrapped = false
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: lineHeight)
        layer.position = center
        layer.string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ])
        layer.opacity = 0
        return layer
    }

    /// 统一入场曲线：0.22,0.61,0.36,1 是一条起步快、收尾极缓的 ease-out，观感更"丝滑"
    private func fadeIn(_ layer: CALayer, delay: TimeInterval, duration: TimeInterval, rise: CGFloat) {
        let begin = CACurrentMediaTime() + delay
        let curve = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = duration
        opacity.beginTime = begin
        opacity.fillMode = .backwards
        opacity.isRemovedOnCompletion = false
        opacity.timingFunction = curve
        layer.add(opacity, forKey: "rr.fadeIn")
        layer.opacity = 1

        if rise != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -rise
            move.toValue = 0
            move.duration = duration
            move.beginTime = begin
            move.fillMode = .backwards
            move.isRemovedOnCompletion = false
            move.timingFunction = curve
            layer.add(move, forKey: "rr.riseIn")
        }
    }

    // MARK: - 循环休息画面

    /// 提醒动画正常播完后落进循环休息画面（伪熄屏）。
    /// countdownSeconds > 0 时显示倒计时，归零后自动结束休息。
    /// 返回 false 表示影片不可用，调用方应退回原来的「真熄屏」行为。
    @discardableResult
    func enterRestLoop(countdownSeconds: Int = 0) -> Bool {
        guard !isLooping else { return true }
        guard let view = windows.first?.contentView,
              let root = view.layer,
              startLoopVideo(in: view, root: root) else {
            logDebug("循环影片不可用，退回真熄屏")
            return false
        }

        isLooping = true

        // 提醒内容整体淡出：除背景层和刚插入的影片层之外，全部渐隐。
        // 必须先 removeAllAnimations —— 入场动画用的是 fillMode=.backwards +
        // isRemovedOnCompletion=false，留在层上的动画会一直把 opacity 顶回 1，
        // 直接改模型值会被它盖掉，看起来就是「淡不出去」。
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.6, 1.0))
        for layer in root.sublayers ?? [] {
            if layer === bgLayer || layer === videoLayer { continue }
            layer.removeAllAnimations()
            layer.opacity = 0
        }
        CATransaction.commit()

        // 循环期间屏幕上只留两样东西：剩余时间 + 怎么结束
        showLoopHint(in: view, root: root)
        if countdownSeconds > 0 {
            showCountdown(in: view, root: root, seconds: countdownSeconds)
            logDebug("休息倒计时启动：\(countdownSeconds)s")
        }

        return true
    }

    private func startLoopVideo(in view: NSView, root: CALayer) -> Bool {
        guard let url = Bundle.main.url(forResource: BreakOverlay.loopVideoName,
                                        withExtension: "mp4") else {
            return false
        }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .advance

        let vLayer = AVPlayerLayer(player: player)
        vLayer.frame = view.bounds
        vLayer.videoGravity = .resizeAspectFill
        vLayer.opacity = 0

        // 插到背景之上、内容层之下
        root.insertSublayer(vLayer, at: 1)

        // 无缝循环：交给 AVPlayerLooper 在解码层交替 item。
        // 绝不能监听 didPlayToEndTime 再 seek(to: .zero) —— 那会闪一帧黑。
        // 注意 loopCount 是只读的（已循环次数），不要在创建后去设它；
        // AVPlayerLooper 默认就一直循环，直到 player 被暂停。
        let lp = AVPlayerLooper(player: player, templateItem: item)

        queuePlayer = player
        looper = lp
        videoLayer = vLayer

        player.play()

        // 与内容淡出重叠的入场：延迟 0.2s，时长 0.8s
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.8
        fade.beginTime = CACurrentMediaTime() + 0.2
        fade.fillMode = .backwards
        fade.isRemovedOnCompletion = false
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
        vLayer.add(fade, forKey: "rr.videoFadeIn")
        vLayer.opacity = 1

        // 注意：不要在这里读 item.duration —— 此时 item 还没加载完，会拿到 nan
        logDebug("循环影片已启动：\(url.lastPathComponent)")
        return true
    }

    private func showLoopHint(in view: NSView, root: CALayer) {
        let h = view.bounds.height
        let hint = textLayer(text: "跟着光晕慢慢呼吸 · 动一下鼠标或按 Esc 结束",
                             font: NSFont.systemFont(ofSize: 13, weight: .regular),
                             color: NSColor(white: 1.0, alpha: 0.38),
                             kern: 2,
                             width: view.bounds.width,
                             center: CGPoint(x: view.bounds.width / 2, y: h - h * 0.885),
                             lineHeight: 20,
                             scale: view.window?.backingScaleFactor ?? 2.0)
        root.addSublayer(hint)
        fadeIn(hint, delay: 0.7, duration: 0.9, rise: 0)
    }

    // MARK: - 休息倒计时

    private func showCountdown(in view: NSView, root: CALayer, seconds: Int) {
        countdownDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        countdownLastShown = -1
        countdownFinished = false

        let h = view.bounds.height
        let layer = textLayer(text: countdownText(seconds),
                              font: countdownFont,
                              color: breakCountdownColor,
                              kern: 1,
                              width: view.bounds.width,
                              center: CGPoint(x: view.bounds.width / 2, y: h - h * 0.72),
                              lineHeight: 46,
                              scale: view.window?.backingScaleFactor ?? 2.0)
        root.addSublayer(layer)
        countdownLayer = layer
        fadeIn(layer, delay: 0.55, duration: 0.9, rise: 0)

        // 0.2 秒一跳，但只在「秒数真的变了」时重绘文字。
        // 跳得比 1 秒密是为了让边界那一秒及时翻牌，不依赖 Timer 的准点。
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tickCountdown()
        }
    }

    /// 等宽数字 + 细字重：数字跳动时宽度不变，不会左右抖
    private var countdownFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .light)
    }

    private var breakCountdownColor: NSColor {
        NSColor(white: 1.0, alpha: 0.62)
    }

    private func countdownText(_ seconds: Int) -> String {
        let total = max(0, seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func setCountdownText(_ str: String) {
        guard let layer = countdownLayer else { return }
        // 必须关掉隐式动画：否则每秒更新字符串都会被淡入淡出动画拖一下，看起来在闪
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = NSAttributedString(string: str, attributes: [
            .font: countdownFont,
            .foregroundColor: breakCountdownColor,
            .kern: 1
        ])
        CATransaction.commit()
    }

    private func tickCountdown() {
        guard !countdownFinished, let deadline = countdownDeadline else { return }
        let remain = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        guard remain != countdownLastShown else { return }
        countdownLastShown = remain
        setCountdownText(countdownText(remain))

        if remain <= 0 {
            finishCountdown()
        }
    }

    private func finishCountdown() {
        countdownFinished = true
        countdownTimer?.invalidate()
        countdownTimer = nil

        // 「休息完成」另起一层做交叉淡入。
        // CATextLayer.string 不是可动画属性，直接改字符串永远是硬切，
        // 所以只能新旧两层叠着换。
        if let view = windows.first?.contentView,
           let root = view.layer,
           let old = countdownLayer {
            let done = textLayer(text: "休息完成",
                                 font: countdownFont,
                                 color: breakCountdownColor,
                                 kern: 1,
                                 width: view.bounds.width,
                                 center: old.position,
                                 lineHeight: 46,
                                 scale: view.window?.backingScaleFactor ?? 2.0)
            root.addSublayer(done)
            fadeIn(done, delay: 0, duration: 0.45, rise: 0)

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            old.opacity = 0
            CATransaction.commit()

            countdownLayer = done
        }

        logDebug("休息倒计时结束，准备收起休息画面")
        // 留足时间让人看清「休息完成」再收 —— 太短会像刚显示就跳回桌面
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.onExitLoop?()
        }
    }

    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownLayer?.removeFromSuperlayer()
        countdownLayer = nil
        countdownDeadline = nil
        countdownLastShown = -1
        countdownFinished = false
    }

    private func stopLoopVideo() {
        queuePlayer?.pause()
        if let vLayer = videoLayer {
            vLayer.removeAllAnimations()
            vLayer.removeFromSuperlayer()
        }
        videoLayer = nil
        looper = nil
        queuePlayer = nil
    }
}
