import Cocoa
import CoreGraphics

/// 微休息全屏指引（Micro-break Overlay）
///
/// 专为 20-20-20 与眼科「泪膜重涂」临床动作设计的 10~15 秒非侵入式微休息。
///
/// 视觉与动作节拍：
///   - 第 1 步 (0.0s ~ 2.5s)：闭紧双眼 2 秒（上下睑缘完全贴合，泵压睑板腺分泌脂质）
///   - 第 2 步 (2.5s ~ 6.0s)：自然睁开缓慢眨眼（脂质层铺展重涂，锁水防蒸发）
///   - 第 3 步 (6.0s ~ 结束前 4 秒)：远眺 6 米以外（不要看手机，睫状肌彻底松开）
///   - 第 4 步 (最后 4 秒)：回到屏幕前的最后一句提醒 —— 记得多眨眼，图标当场眨两下
///
/// 第 4 步刻意放在收尾：前面三步是在「停下」，最后这几秒要做的是「接回去」——
/// 人从全屏遮罩回到内容时，注意力立刻被占满，最容易忘记的就是眨眼。
///
/// 极简退出保障：
///   按 Esc、空格、回车或任意键，或轻点鼠标，均可瞬间平滑淡出，绝不强行锁死，打破抵触心理。
final class MicroBreakOverlay {

    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var timer: Timer?
    private var finished = false
    private let duration: TimeInterval
    private var deadline: Date?

    // 动态可切换图层
    private var iconLayer: CALayer?
    private var iconWrapLayer: CALayer?
    private var stepTagLayer: CATextLayer?
    private var titleLayer: CATextLayer?
    private var subtitleLayer: CATextLayer?
    private var countdownLayer: CATextLayer?
    private var fillLayer: CALayer?
    private var fillGlowLayer: CALayer?
    private var currentPhase: Int = -1

    // 内容层集合（入场动画后需要引用）
    private var contentLayers: [CALayer] = []

    var onFinish: ((Bool) -> Void)?

    init(duration: TimeInterval = 15.0) {
        self.duration = max(5.0, duration)
    }

    var isShowing: Bool { !windows.isEmpty }

    func present() {
        guard windows.isEmpty else { return }
        finished = false
        currentPhase = -1
        deadline = Date().addingTimeInterval(duration)

        for (index, screen) in NSScreen.screens.enumerated() {
            let win = OverlayWindow(contentRect: screen.frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false,
                                   screen: screen)
            // 略低于系统大休息遮罩，但高于普通应用
            win.level = NSWindow.Level(rawValue: 1400)
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.isMovable = false
            win.animationBehavior = .none
            win.contentView?.wantsLayer = true

            if let content = win.contentView {
                buildLayers(in: content, withContent: index == 0)
            }
            win.orderFrontRegardless()
            windows.append(win)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        // 键盘监听：按 Esc、空格、回车或任意键均可提前跳过
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            self.dismiss(animated: true, naturally: false)
            return nil
        }

        // 鼠标点击任意处直接跳过
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            self.dismiss(animated: true, naturally: false)
            return nil
        }

        // 计时调度（每 0.2 秒检查一次剩余时间与步骤切换）
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
        tick() // 立即执行第一拍
    }

    func dismiss(animated: Bool = true, naturally: Bool = false) {
        guard !finished else { return }
        finished = true

        removeMonitors()
        timer?.invalidate()
        timer = nil

        let wins = windows
        windows.removeAll()

        let cb = onFinish
        onFinish = nil

        guard animated else {
            wins.forEach { $0.orderOut(nil) }
            cb?(naturally)
            return
        }

        // 散开式淡出：内容轻微放大，营造「消散」感
        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.6)
        CATransaction.setAnimationTimingFunction(curve)
        for win in wins {
            for layer in win.contentView?.layer?.sublayers ?? [] {
                layer.transform = CATransform3DMakeScale(1.04, 1.04, 1.0)
            }
        }
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            ctx.timingFunction = curve
            wins.forEach { $0.animator().alphaValue = 0 }
        } completionHandler: {
            wins.forEach { $0.orderOut(nil) }
            cb?(naturally)
        }
    }

    private func removeMonitors() {
        if let km = keyMonitor { NSEvent.removeMonitor(km) }
        if let mm = mouseMonitor { NSEvent.removeMonitor(mm) }
        keyMonitor = nil
        mouseMonitor = nil
    }

    // MARK: - 步骤流转

    private func tick() {
        guard let deadline = deadline else { return }
        let now = Date()
        let elapsed = max(0, duration - deadline.timeIntervalSince(now))
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))

        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            updateCountdown(text: "0s")
            // 倒计时自然走满
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.dismiss(animated: true, naturally: true)
            }
            return
        }

        updateCountdown(text: "\(remaining)s")

        // 步骤判断
        //
        // 收尾阶段（第 4 步）固定占最后 4 秒，但起点不早于 8 秒 ——
        // 否则把时长调成 10 秒时，第 3 步「远眺」会被挤到只剩半秒，等于没有。
        let blinkPhaseStart = max(8.0, duration - 4.0)
        let targetPhase: Int
        if elapsed < 2.5 {
            targetPhase = 1 // 闭紧双眼 2 秒
        } else if elapsed < 6.0 {
            targetPhase = 2 // 自然睁开重涂
        } else if elapsed < blinkPhaseStart {
            targetPhase = 3 // 远眺 6 米松睫状肌
        } else {
            targetPhase = 4 // 收尾：记得多眨眼
        }

        if targetPhase != currentPhase {
            currentPhase = targetPhase
            applyPhase(phase: targetPhase)
        }
    }

    private func applyPhase(phase: Int) {
        let symbolName: String
        let stepText: String
        let titleText: String
        let subText: String

        switch phase {
        case 1:
            symbolName = "eye.slash.fill"
            stepText = "步骤 1/4 · 睑板腺泵压"
            titleText = "闭紧双眼 2 秒"
            subText = "上下睑缘完全贴合 · 挤压睑板腺分泌脂质"
        case 2:
            symbolName = "eye.fill"
            stepText = "步骤 2/4 · 泪膜重涂"
            titleText = "自然睁开 · 缓慢眨眼"
            subText = "脂质层均匀铺展 · 完成泪膜重涂锁水"
        case 3:
            // 这里原来用 eye.circle.fill，白色 palette 下圆形和里面的眼睛同色，
            // 渲染出来是一坨白色实心圆。换成实心双筒望远镜，「往远处看」的意思也更直接。
            symbolName = "binoculars.fill"
            stepText = "步骤 3/4 · 睫状肌放松"
            titleText = "看向 6 米以外"
            subText = "这几秒不要看手机 · 让睫状肌彻底松开"
        default:
            symbolName = "eye.fill"
            stepText = "步骤 4/4 · 眨眼保护"
            titleText = "记得多眨眼"
            subText = "回到屏幕后最容易忘的就是眨眼 · 每眨一次都在重铺泪膜"
        }

        // ── 图标切换：spring 弹跳 + 交叉淡入
        if let iconLayer = iconLayer, let wrap = iconWrapLayer {
            let scale = windows.first?.backingScaleFactor ?? 2.0
            if let img = renderSymbolImage(name: symbolName, pointSize: 84) {
                var proposed = CGRect(origin: .zero, size: img.size)
                if let cg = img.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
                    // 先微缩再弹回：营造「换一步」的节奏感
                    let pop = CASpringAnimation(keyPath: "transform.scale")
                    pop.fromValue = 0.75
                    pop.toValue = 1.0
                    pop.mass = 0.8
                    pop.stiffness = 200
                    pop.damping = 12
                    pop.duration = pop.settlingDuration
                    wrap.add(pop, forKey: "mb.iconPop")

                    // 图标内容交叉淡入
                    let crossFade = CABasicAnimation(keyPath: "opacity")
                    crossFade.fromValue = 0.0
                    crossFade.toValue = 1.0
                    crossFade.duration = 0.3
                    crossFade.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    iconLayer.add(crossFade, forKey: "mb.iconCrossFade")

                    iconLayer.contents = cg
                    iconLayer.contentsScale = scale
                }
            }
        }

        // ── 第 4 步：让这只眼睛当场眨两下
        // 光看文字「记得多眨眼」很容易读完就忘；图标真的眨一下，会带出镜像性的眨眼反射。
        if phase == 4, let iconLayer = iconLayer {
            addBlinkAnimation(to: iconLayer)
        }

        // ── 文字切换：交叉淡入 + 轻微上升
        crossFadeText(layer: stepTagLayer, text: stepText,
                      font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                      color: NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.95),
                      kern: 2.5)
        crossFadeText(layer: titleLayer, text: titleText,
                      font: NSFont.systemFont(ofSize: 52, weight: .bold),
                      color: NSColor(srgbRed: Style.Text.titleR, green: Style.Text.titleG, blue: Style.Text.titleB, alpha: 1.0),
                      kern: 3.0)
        crossFadeText(layer: subtitleLayer, text: subText,
                      font: NSFont.systemFont(ofSize: 21, weight: .regular),
                      color: NSColor(srgbRed: Style.Text.subtitleR, green: Style.Text.subtitleG, blue: Style.Text.subtitleB, alpha: 1.0),
                      kern: 1.5)
    }

    /// 文字交叉淡入 + 轻微上升动效，替代硬切
    private func crossFadeText(layer: CATextLayer?, text: String, font: NSFont, color: NSColor, kern: CGFloat) {
        guard let layer = layer else { return }

        // 淡入
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.35
        fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
        layer.add(fade, forKey: "mb.textFade")

        // 轻微上浮
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -8.0
        rise.toValue = 0.0
        rise.duration = 0.35
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
        layer.add(rise, forKey: "mb.textRise")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ])
        CATransaction.commit()
    }

    private func updateCountdown(text: String) {
        guard let layer = countdownLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.string = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(white: 1.0, alpha: 0.6),
            .kern: 1.0
        ])
        CATransaction.commit()
    }

    // MARK: - 入场动画曲线

    /// 统一入场曲线：0.22,0.61,0.36,1 是一条起步快、收尾极缓的 ease-out，观感更"丝滑"。
    /// 与 BreakOverlay.fadeIn 使用同一组贝塞尔参数。
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
        layer.add(opacity, forKey: "mb.fadeIn")
        layer.opacity = 1

        if rise != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -rise    // macOS CALayer 原点在左下角，负值 = 从上方移入
            move.toValue = 0
            move.duration = duration
            move.beginTime = begin
            move.fillMode = .backwards
            move.isRemovedOnCompletion = false
            move.timingFunction = curve
            layer.add(move, forKey: "mb.riseIn")
        }
    }

    // MARK: - Layer 构建

    private func buildLayers(in view: NSView, withContent: Bool) {
        guard let root = view.layer else { return }
        let w = view.bounds.width
        let h = view.bounds.height
        let scale = view.window?.backingScaleFactor ?? 2.0

        func fromTop(_ offset: CGFloat) -> CGFloat { h - offset }

        // ══════════════════════════════════════════════════
        // 背景：中心微亮的深色径向渐变
        // ══════════════════════════════════════════════════
        let bg = CAGradientLayer()
        bg.type = .radial
        bg.frame = CGRect(x: 0, y: 0, width: w, height: h)
        bg.colors = [
            NSColor(srgbRed: Style.Background.innerR, green: Style.Background.innerG, blue: Style.Background.innerB, alpha: 0.96).cgColor,
            NSColor(srgbRed: Style.Background.outerR, green: Style.Background.outerG, blue: Style.Background.outerB, alpha: 0.97).cgColor
        ]
        bg.locations = [0, 1]
        bg.startPoint = CGPoint(x: 0.5, y: Style.Background.centerY)
        bg.endPoint = CGPoint(x: 1.15, y: 1.3)
        root.addSublayer(bg)
        fadeIn(bg, delay: 0, duration: 0.5, rise: 0)

        guard withContent else { return }

        // ── 布局锚点 ──
        let glowCenter = CGPoint(x: w / 2, y: fromTop(h * 0.38))
        let stepCenter = CGPoint(x: w / 2, y: fromTop(h * 0.51))
        let titleCenter = CGPoint(x: w / 2, y: fromTop(h * 0.575))
        let subtitleCenter = CGPoint(x: w / 2, y: fromTop(h * 0.645))
        let cdCenter = CGPoint(x: w / 2, y: fromTop(h * 0.735))
        let barCenter = CGPoint(x: w / 2, y: fromTop(h * 0.775))
        let hintCenter = CGPoint(x: w / 2, y: fromTop(h * 0.88))

        // ══════════════════════════════════════════════════
        // 顶部模式徽标
        // ══════════════════════════════════════════════════
        let topBadgeCenter = CGPoint(x: w / 2, y: fromTop(h * 0.18))
        let topBadge = makeTextLayer(text: "🌱 微休息 · 泪膜重涂操",
                                    font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                    color: NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.7),
                                    kern: 3.0,
                                    width: w,
                                    center: topBadgeCenter,
                                    lineHeight: 24,
                                    scale: scale)
        root.addSublayer(topBadge)
        fadeIn(topBadge, delay: 0.15, duration: 0.8, rise: 10)

        // ══════════════════════════════════════════════════
        // 外层光环 —— 微妙旋转的薄圆环，增加空间层次
        // ══════════════════════════════════════════════════
        let ringSize: CGFloat = 320
        let ring = CAShapeLayer()
        let ringPath = CGMutablePath()
        ringPath.addEllipse(in: CGRect(x: -ringSize / 2, y: -ringSize / 2, width: ringSize, height: ringSize))
        ring.path = ringPath
        ring.fillColor = nil
        ring.strokeColor = NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.08).cgColor
        ring.lineWidth = 1.0
        ring.lineDashPattern = [4, 8]
        ring.position = glowCenter
        root.addSublayer(ring)
        fadeIn(ring, delay: 0.2, duration: 1.0, rise: 0)

        let ringRotate = CABasicAnimation(keyPath: "transform.rotation.z")
        ringRotate.fromValue = 0
        ringRotate.toValue = CGFloat.pi * 2
        ringRotate.duration = 40.0
        ringRotate.repeatCount = .infinity
        ring.add(ringRotate, forKey: "mb.ringRotate")

        // ══════════════════════════════════════════════════
        // 中央呼吸光晕（外wrapper管入场，内层管呼吸，避免同一属性上两个动画打架）
        // ══════════════════════════════════════════════════
        let glowWrap = CALayer()
        let glowSize: CGFloat = 680
        glowWrap.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glowWrap.position = glowCenter
        root.addSublayer(glowWrap)
        fadeIn(glowWrap, delay: 0.08, duration: 1.0, rise: 0)

        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = glowWrap.bounds
        glow.colors = [
            NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.28).cgColor,
            NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.0).cgColor
        ]
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glowWrap.addSublayer(glow)

        // 光晕呼吸：opacity + scale 双重动效，比单一 scale 更有层次
        let glowBreatheOpacity = CABasicAnimation(keyPath: "opacity")
        glowBreatheOpacity.fromValue = 0.5
        glowBreatheOpacity.toValue = 1.0
        glowBreatheOpacity.duration = 2.6
        glowBreatheOpacity.autoreverses = true
        glowBreatheOpacity.repeatCount = .infinity
        glowBreatheOpacity.beginTime = CACurrentMediaTime() + 1.0
        glowBreatheOpacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(glowBreatheOpacity, forKey: "mb.glowBreatheOp")
        glow.opacity = 1

        let glowBreatheScale = CABasicAnimation(keyPath: "transform.scale")
        glowBreatheScale.fromValue = 0.93
        glowBreatheScale.toValue = 1.07
        glowBreatheScale.duration = 2.6
        glowBreatheScale.autoreverses = true
        glowBreatheScale.repeatCount = .infinity
        glowBreatheScale.beginTime = CACurrentMediaTime() + 1.0
        glowBreatheScale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(glowBreatheScale, forKey: "mb.glowBreatheScale")

        // ══════════════════════════════════════════════════
        // 步骤图标（spring 弹入 + 呼吸缩放）
        // ══════════════════════════════════════════════════
        let iconWrap = CALayer()
        let iconWrapSize: CGFloat = 160
        iconWrap.bounds = CGRect(x: 0, y: 0, width: iconWrapSize, height: iconWrapSize)
        iconWrap.position = glowCenter
        root.addSublayer(iconWrap)
        iconWrapLayer = iconWrap

        let icon = CALayer()
        let iconSize: CGFloat = 130
        icon.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        icon.position = CGPoint(x: iconWrapSize / 2, y: iconWrapSize / 2)
        icon.contentsGravity = .resizeAspect
        iconWrap.addSublayer(icon)
        iconLayer = icon

        // 入场：spring 弹入
        fadeIn(iconWrap, delay: 0.18, duration: 0.5, rise: 0)

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.6
        pop.toValue = 1.0
        pop.mass = 1.0
        pop.stiffness = 180
        pop.damping = 13
        pop.duration = pop.settlingDuration
        pop.beginTime = CACurrentMediaTime() + 0.18
        pop.fillMode = .backwards
        pop.isRemovedOnCompletion = false
        iconWrap.add(pop, forKey: "mb.popIn")
        iconWrap.transform = CATransform3DIdentity

        // 图标呼吸：与光晕同步
        let iconBreathe = CABasicAnimation(keyPath: "transform.scale")
        iconBreathe.fromValue = 1.0
        iconBreathe.toValue = 1.06
        iconBreathe.duration = 2.6
        iconBreathe.autoreverses = true
        iconBreathe.repeatCount = .infinity
        iconBreathe.beginTime = CACurrentMediaTime() + 1.0
        iconBreathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        icon.add(iconBreathe, forKey: "mb.iconBreathe")

        // ══════════════════════════════════════════════════
        // 步骤小标题
        // ══════════════════════════════════════════════════
        let stepLayer = makeTextLayer(text: "",
                                     font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                     color: NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.9),
                                     kern: 2.5,
                                     width: w,
                                     center: stepCenter,
                                     lineHeight: 22,
                                     scale: scale)
        root.addSublayer(stepLayer)
        fadeIn(stepLayer, delay: 0.35, duration: 0.6, rise: 14)
        stepTagLayer = stepLayer

        // ══════════════════════════════════════════════════
        // 主标题
        // ══════════════════════════════════════════════════
        let tLayer = makeTextLayer(text: "",
                                  font: NSFont.systemFont(ofSize: 52, weight: .bold),
                                  color: NSColor(srgbRed: Style.Text.titleR, green: Style.Text.titleG, blue: Style.Text.titleB, alpha: 1.0),
                                  kern: 3.0,
                                  width: w,
                                  center: titleCenter,
                                  lineHeight: 70,
                                  scale: scale)
        root.addSublayer(tLayer)
        fadeIn(tLayer, delay: 0.42, duration: 0.7, rise: 20)
        titleLayer = tLayer

        // ══════════════════════════════════════════════════
        // 副标题 / 动作要领
        // ══════════════════════════════════════════════════
        let sLayer = makeTextLayer(text: "",
                                  font: NSFont.systemFont(ofSize: 21, weight: .regular),
                                  color: NSColor(srgbRed: Style.Text.subtitleR, green: Style.Text.subtitleG, blue: Style.Text.subtitleB, alpha: 1.0),
                                  kern: 1.5,
                                  width: w,
                                  center: subtitleCenter,
                                  lineHeight: 34,
                                  scale: scale)
        root.addSublayer(sLayer)
        fadeIn(sLayer, delay: 0.55, duration: 0.7, rise: 16)
        subtitleLayer = sLayer

        // ══════════════════════════════════════════════════
        // 倒计时数字
        // ══════════════════════════════════════════════════
        let cdLayer = makeTextLayer(text: "\(Int(duration))s",
                                   font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
                                   color: NSColor(white: 1.0, alpha: 0.6),
                                   kern: 1.0,
                                   width: w,
                                   center: cdCenter,
                                   lineHeight: 24,
                                   scale: scale)
        root.addSublayer(cdLayer)
        fadeIn(cdLayer, delay: 0.65, duration: 0.6, rise: 0)
        countdownLayer = cdLayer

        // ══════════════════════════════════════════════════
        // 进度条：线性走满，带发光尾迹
        // ══════════════════════════════════════════════════
        let barWidth: CGFloat = 360
        let barHeight: CGFloat = 4
        let barStart: TimeInterval = 0.8
        let barDuration = max(0.6, duration - barStart)

        let track = CALayer()
        track.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        track.position = barCenter
        track.cornerRadius = barHeight / 2
        track.backgroundColor = NSColor(white: 1.0, alpha: 0.10).cgColor
        root.addSublayer(track)
        fadeIn(track, delay: 0.7, duration: 0.6, rise: 0)

        let fill = CALayer()
        fill.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.position = CGPoint(x: barCenter.x - barWidth / 2, y: barCenter.y)
        fill.cornerRadius = barHeight / 2
        fill.backgroundColor = NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 1.0).cgColor
        fill.opacity = 0
        root.addSublayer(fill)
        fillLayer = fill

        let progressAnim = CABasicAnimation(keyPath: "transform.scale.x")
        progressAnim.fromValue = 0.001
        progressAnim.toValue = 1.0
        progressAnim.duration = barDuration
        progressAnim.beginTime = CACurrentMediaTime() + barStart
        progressAnim.fillMode = .backwards
        progressAnim.isRemovedOnCompletion = false
        progressAnim.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.add(progressAnim, forKey: "mb.progress")
        fill.transform = CATransform3DIdentity

        let fillFade = CABasicAnimation(keyPath: "opacity")
        fillFade.fromValue = 0
        fillFade.toValue = 1
        fillFade.duration = 0.5
        fillFade.beginTime = CACurrentMediaTime() + 0.7
        fillFade.fillMode = .backwards
        fillFade.isRemovedOnCompletion = false
        fill.add(fillFade, forKey: "mb.fillFadeIn")
        fill.opacity = 1

        // 进度条发光尾迹
        let fillGlow = CALayer()
        fillGlow.bounds = CGRect(x: 0, y: 0, width: barWidth, height: barHeight + 10)
        fillGlow.anchorPoint = CGPoint(x: 0, y: 0.5)
        fillGlow.position = CGPoint(x: barCenter.x - barWidth / 2, y: barCenter.y)
        fillGlow.cornerRadius = (barHeight + 10) / 2
        fillGlow.backgroundColor = NSColor(srgbRed: Style.Accent.r, green: Style.Accent.g, blue: Style.Accent.b, alpha: 0.25).cgColor
        fillGlow.opacity = 0
        root.insertSublayer(fillGlow, below: fill)
        fillGlowLayer = fillGlow

        let glowProgress = CABasicAnimation(keyPath: "transform.scale.x")
        glowProgress.fromValue = 0.001
        glowProgress.toValue = 1.0
        glowProgress.duration = barDuration
        glowProgress.beginTime = CACurrentMediaTime() + barStart
        glowProgress.fillMode = .backwards
        glowProgress.isRemovedOnCompletion = false
        glowProgress.timingFunction = CAMediaTimingFunction(name: .linear)
        fillGlow.add(glowProgress, forKey: "mb.glowProgress")
        fillGlow.transform = CATransform3DIdentity

        let glowFillFade = CABasicAnimation(keyPath: "opacity")
        glowFillFade.fromValue = 0
        glowFillFade.toValue = 1
        glowFillFade.duration = 0.5
        glowFillFade.beginTime = CACurrentMediaTime() + 0.7
        glowFillFade.fillMode = .backwards
        glowFillFade.isRemovedOnCompletion = false
        fillGlow.add(glowFillFade, forKey: "mb.glowFillFadeIn")
        fillGlow.opacity = 1

        // 发光层呼吸脉冲
        let glowPulse = CABasicAnimation(keyPath: "opacity")
        glowPulse.fromValue = 0.15
        glowPulse.toValue = 0.35
        glowPulse.duration = 1.3
        glowPulse.autoreverses = true
        glowPulse.repeatCount = .infinity
        glowPulse.beginTime = CACurrentMediaTime() + barStart + 0.5
        glowPulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fillGlow.add(glowPulse, forKey: "mb.glowPulse")

        // ══════════════════════════════════════════════════
        // 底部跳过提示
        // ══════════════════════════════════════════════════
        let hintLayer = makeTextLayer(text: "按任意键或动鼠标可提前跳过 · 倒计时结束自动收起",
                                     font: NSFont.systemFont(ofSize: 12, weight: .regular),
                                     color: NSColor(white: 1.0, alpha: 0.3),
                                     kern: 2.0,
                                     width: w,
                                     center: hintCenter,
                                     lineHeight: 20,
                                     scale: scale)
        root.addSublayer(hintLayer)
        fadeIn(hintLayer, delay: 0.9, duration: 0.8, rise: 0)
    }

    // MARK: - 辅助

    private func makeTextLayer(text: String,
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
        layer.opacity = 0   // 入场时由 fadeIn 控制
        return layer
    }

    /// 图标眨两下：`contents` 在「睁眼」「半闭」两张 SF Symbol 之间跳。
    /// 用 CAKeyframeAnimation 而不是另起一条定时器 —— 动画结束自动回到睁眼状态，不用收尾。
    private func addBlinkAnimation(to layer: CALayer) {
        guard let open = cgImage(symbol: "eye.fill"),
              let closed = cgImage(symbol: "eye.half.closed.fill") else { return }

        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = [open, closed, open, closed, open] as [Any]
        anim.keyTimes = [0.0, 0.2, 0.45, 0.7, 1.0]
        anim.duration = 0.9
        // 收尾窗口 2~4 秒：按窗口长度铺满，别眨一下就停在那里干等
        let window = duration - max(8.0, duration - 4.0)
        anim.repeatCount = Float(max(1, Int(window / 0.9)))
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "mb.iconBlink")
    }

    private func cgImage(symbol: String, pointSize: CGFloat = 84) -> CGImage? {
        guard let img = renderSymbolImage(name: symbol, pointSize: pointSize) else { return nil }
        var proposed = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    private func renderSymbolImage(name: String, pointSize: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }
}
