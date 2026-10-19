# RestReminder · 熄屏后循环播放动画 — 方案与生成提示词

> 目标：熄屏提醒动画结束后，不再直接黑屏，而是进入一段无缝循环的「休息片段」，直到用户回来。
> 循环 15 秒，首尾帧完全一致，循环点无跳变。

---

## 一、先定一个必须做的取舍

**现在的实现和"循环播放"在物理上是互斥的。**

当前链路（`main.swift` L1053-1068）：

```
动画播完 → pmset displaysleepnow → 显示器断电 → 1.6s 后遮罩收回
```

`pmset displaysleepnow` 会把显示器**真正断电**（背光关闭）。屏幕都不亮了，视频没有任何办法播放。所以想要"熄屏后循环播放"，只有两条路：

| 方案 | 做法 | 效果 | 代价 |
|---|---|---|---|
| **A. 伪熄屏**（推荐） | 不调用 pmset，遮罩保持，屏幕全黑底 + 循环视频 | 视觉上"屏幕暗下来进入休息"，实际在播放松画面 | 背光仍亮（LCD）；OLED 上黑像素不发光，几乎等于熄屏 |
| B. 真熄屏 + 唤醒后播放 | 保持 pmset；用户动鼠标唤醒后，才播放片段提示"还没休息够" | 真省电真护眼 | 与"结束后循环播放"的意图不符，是另一套交互 |

**建议走 A。** 语义上从"强制熄屏"变成"强制进入休息画面"——反而更贴护眼工具的本意：逼你抬头，而不是把屏幕关掉。功能名可以顺势改成 **「到点进入休息画面」**。

> 如果你的护眼诉求是"必须彻底断蓝光"，那 A 做不到，应该保留现在的 B 并把视频用在别处。这一条需要你确认。

---

## 二、无缝循环的三层保障

循环看着"丝滑"不是单一环节的事，三层都要做对：

### 第 1 层：像素级 — 首尾帧完全一致

用视频模型的 **首尾帧功能**，把**同一张图**同时作为首帧和尾帧，让模型只补中间的运动。这样循环点两侧的像素**完全相同**，理论上零跳变——比任何提示词里写"seamless loop"都可靠。

这是本方案的核心，也是我强烈建议的做法。

### 第 2 层：播放器级 — 用 AVPlayerLooper，不要手动 seek

```swift
// ✅ 正确：AVQueuePlayer + AVPlayerLooper，切换在解码层完成，无黑帧
let player = AVQueuePlayer()
let looper = AVPlayerLooper(player: player, templateItem: item)
looper.loopCount = .infinite

// ❌ 错误：监听 didPlayToEndTime 再 seek(to: .zero)，每次循环会闪一帧黑
```

### 第 3 层：编码级

`-movflags +faststart`（moov 前置，起播快）、去掉音轨（`-an`）、CRF 18、`yuv420p`。

---

## 三、视频规格

| 项目 | 建议值 | 理由 |
|---|---|---|
| 分辨率 | 1920×1080（1080P） | 当前主屏 3840×2160 是 16:9，`resizeAspectFill` 正好铺满 |
| 宽高比 | 16:9 | 同上 |
| 时长 | 15.0s / 30fps / 450 帧 | 你指定的时长 |
| 音轨 | 无 | app 侧 `isMuted = true`，且循环视频不该有声音 |
| 编码 | H.264 High / CRF 18 / +faststart | 兼容性最稳；追求体积可换 HEVC |
| 体积 | < 25 MB | 随 app 打包，别太大 |
| 存放 | `RestReminder.app/Contents/Resources/rest-loop.mp4` | 由 `build.sh` 拷贝 |

> ⚠️ 注意：遮罩是**每块屏一个窗口，但只有主屏放内容**（`buildLayers(withContent: index == 0)`）。所以视频只铺主屏，副屏保持纯黑。当前主屏是外接 4K，若以后把内建屏（2880×1864 ≈ 1.545:1）设为主屏，16:9 视频会上下裁掉约 3%，可接受。

---

## 四、视觉设计：与现有动画怎么衔接

### 现有动画的视觉参数（从代码里提取，视频必须对齐）

| 元素 | 值 |
|---|---|
| 背景渐变 | 径向，中心 `#14161E` → 边缘 `#040407` |
| 中心位置 | 屏幕宽 50%、高 41.5%（`startPoint y=0.52`） |
| 主色（冷青） | `srgb(0.42, 0.88, 0.80)` = `#6BE0CC` |
| 光晕峰值透明度 | 0.30，直径 720pt |
| 光晕呼吸 | scale/opacity，周期 2.6s，easeInEaseOut |
| 入场曲线 | `cubic-bezier(0.22, 0.61, 0.36, 1.0)` |

### 衔接点设计（关键）

视频**只做背景氛围，不做文字**。文字继续由代码用 `CATextLayer` 叠在视频之上。原因：

1. AI 生成中文必糊、必错字——这是不可修复的硬伤；
2. 文字层由代码控制，可以常驻不参与循环，避免"文字跟着视频重播"的怪异感；
3. 文字永远清晰、随时可改。

所以过渡序列是：

```
进度条走满 (t=0)
  ├─ 文字 / 进度条 / 眼睛图标 一起淡出  0.6s
  └─ 视频层淡入（crossfade 重叠 0.3s） 0.8s
        ↓
   只剩「中心光晕在缓慢呼吸」  ← 视频循环播放
        ↓
   用户动鼠标 / 按 Esc → 视频淡出、亮度恢复 → 计时清零
```

**因此视频的首帧 = 只有中心光晕、无文字、无图标、静息态。** 这样从"光晕+图标"过渡到"只剩光晕"时，光晕本身是连续的，不会有突兀感。

### 15 秒的节奏设计

15 秒 = **一次完整呼吸**，首尾都是静息态：

```
0s ────── 5s ── 7s ──────────── 15s
静息  缓慢扩张  屏息   缓慢收缩回静息
      (吸气)   (保持)    (呼气)
```

选这个节奏的两个理由：
- 首尾都是"静息态" → 首尾帧一致是语义上自然的，不是硬凑；
- 屏幕真的在"呼吸"，用户会不自觉地跟着调整呼吸——这才是护眼工具的额外价值。

---

## 五、生成流程

### 分几段生成？

单次生成通常 5 秒左右。15 秒有两条路：

**路线 1（推荐）：3 段闭环拼接**

用首尾帧串联，构成闭环：

```
关键帧 A（静息） → 关键帧 B（半满） → 关键帧 C（最亮）
   ↑                                      │
   └──────────── 段3（C→A）────────────────┘

段1: A→B  段2: B→C  段3: C→A   → 顺序播放 = 15s，末尾回到 A = 闭环无缝
```

每段的尾帧 = 下一段的首帧（像素级对齐），最后一段的尾帧 = 第一段的首帧。三段拼起来天然闭环。

**路线 2：单段 15 秒**（若模型支持长时长）
不给尾帧，只在提示词里描述完整呼吸周期，后期用 ffmpeg 校验并修正首尾差异。

下面两套提示词都给。

---

## 六、完整提示词

### 6.1 关键帧图提示词（生成 A / B / C 三张）

用图形生成工具产出 1920×1080 的三张图，**只有中心光晕大小不同，其余完全一致**。

**关键帧 A — 静息态（首帧 = 尾帧）**

```text
Minimal abstract background, 16:9, pure digital art, no text of any kind.

A very deep charcoal background, nearly black: center is #14161E, fading radially
outward to #040407 at the edges, extremely subtle and smooth gradient, no visible banding.
The center of the frame is at 50% width and 45% height.

At that center sits one soft, diffuse, circular glow of cyan-teal color #6BE0CC,
about 22% of the frame width in diameter, with very soft feathered edges that dissolve
completely into the dark background. The glow is dim and calm, at its resting state.
No hard edges, no ring outlines, no lens flare spikes.

The whole image is extremely dark, low contrast, restful, no bright areas anywhere.
Slight film grain, perfectly clean and smooth gradients.

Absolutely no text, no letters, no numbers, no words, no logos, no watermarks,
no icons, no UI elements, no people, no objects.
```

**关键帧 B — 半满态**

```text
[与 A 完全相同的前两段背景描述]

At that center sits one soft, diffuse, circular glow of cyan-teal color #6BE0CC,
about 34% of the frame width in diameter, with very soft feathered edges that dissolve
completely into the dark background. The glow is at medium intensity — brighter and
larger than its resting state, mid-way toward its fullest. No hard edges, no ring
outlines, no lens flare spikes.

[其余同 A，包括全部 no text 声明]
```

**关键帧 C — 最亮态**

```text
[与 A 完全相同的前两段背景描述]

At that center sits one soft, diffuse, circular glow of cyan-teal color #6BE0CC,
about 46% of the frame width in diameter, with very soft feathered edges that dissolve
completely into the dark background. The glow is at its brightest and largest, filling
the center with gentle calm light. No hard edges, no ring outlines, no lens flare spikes.

[其余同 A，包括全部 no text 声明]
```

> 三张图**必须用同一段背景描述、同一次生成流程**，否则背景纹理会有差异，拼接时露馅。最稳的做法是：先生成 A，再用"图生图"以 A 为底，只要求"光晕放大到 34% / 46%，其余完全不变、像素级保留背景"。

---

### 6.2 视频提示词（首尾帧模式）

**段 1：A → B（静息 → 半满，吸气前半程）**

```text
A single continuous slow inhale.

The soft cyan-teal glow at the center expands gently and evenly outward, growing from
its small resting size to about half of its full size. Its brightness rises slightly
as it grows, and its soft feathered edge stays soft the entire time.

The movement is extremely smooth and continuous, like a slow-motion breath viewed
through still air — constant, even, unhurried, with no sudden shifts, no acceleration
spikes, no pulsing.

Camera is completely static and locked off. No zoom, no pan, no tilt, no rotation,
no parallax, no depth-of-field change.

The deep charcoal background stays perfectly still. Nothing else moves in the frame.

No text, no letters, no numbers, no words, no logos, no watermarks, no icons,
no people, no animals, no objects.
```

**段 2：B → C（半满 → 最亮，吸气后半程 / 到顶）**

```text
A single continuous slow continuation of the inhale.

The soft cyan-teal glow continues expanding smoothly from half size to its full,
brightest extent — about 46% of the frame width. It reaches a gentle peak of light
in the final moments of the clip and gently settles there. The feathered edge stays
soft throughout.

The motion stays perfectly smooth and even — constant, unhurried, no discrete steps,
no flicker, no abrupt changes.

Camera is completely static and locked off. No zoom, no pan, no tilt, no rotation,
no parallax, no depth-of-field change.

The deep charcoal background remains still. Nothing else moves in the frame.

No text, no letters, no numbers, no words, no logos, no watermarks, no icons,
no people, no animals, no objects.
```

**段 3：C → A（最亮 → 静息，呼气）**

```text
A single continuous slow exhale.

The soft cyan-teal glow contracts smoothly and evenly from its full, brightest size
back down to a small, dim, calm resting state, ending exactly as it began. The motion
is very gradual and slows gently as it settles, like a breath released and finally
at rest. The feathered edge stays soft throughout.

No sudden shifts, no flicker, no pulsing, no bounce at the end — it simply comes
to rest.

Camera is completely static and locked off. No zoom, no pan, no tilt, no rotation,
no parallax, no depth-of-field change.

The deep charcoal background stays still. Nothing else moves in the frame.

No text, no letters, no numbers, no words, no logos, no watermarks, no icons,
no people, no animals, no objects.
```

**（若模型支持长时长）单段 15 秒版本**

```text
One complete, slow, single breathing cycle, lasting exactly 15 seconds.

Phase 1 — first 5 seconds: the soft cyan-teal glow at the center expands gently and
evenly from its small resting size outward.
Phase 2 — next 2 seconds: it holds at its brightest and largest, still and calm.
Phase 3 — final 8 seconds: it contracts smoothly and gradually back down until it
returns exactly to its resting state, identical to how the video began.

The motion is extremely smooth and continuous throughout, like a slow-motion breath —
no sudden shifts, no flicker, no acceleration spikes, no second pulse.

The first frame and the last frame must be visually identical so the video loops
perfectly with no visible seam.

Camera completely static and locked off — no zoom, no pan, no tilt, no rotation,
no parallax. The deep charcoal background stays perfectly still.

No text, no letters, no numbers, no words, no logos, no watermarks, no icons,
no people, no animals, no objects.
```

---

### 6.3 负向提示词（三段通用）

```text
text, letters, words, subtitles, captions, typography, numbers, watermark, logo,
signature, UI, interface, hud, icons, emoji, people, faces, hands, eyes, animals,
objects, camera movement, zoom, pan, tilt, rotation, parallax, dolly, handheld shake,
scene change, hard cut, transition, strobing, flicker, flash, sudden brightness change,
fast motion, high contrast, blown highlights, lens flare, hard edges, ring artifacts,
banding, color banding, dithering artifacts, heavy noise, compression artifacts,
blurriness, low quality, jpeg artifacts, oversaturated, purple, magenta, orange, red
```

> 负向里特意压制了 **text / subtitles / watermark**（中文糊字是最大的返工源）、**camera movement**（镜头一动循环必崩）、**hard cut / scene change**（模型爱自作主张加转场）。

---

### 6.4 主题变体（如果不想用光晕）

换主题时，把上面提示词里"glow 的描述"整段替换，其余（首尾帧、静止镜头、no text）全部保留：

**变体 B — 深海微光**

```text
At the center, a very slow drifting cluster of tiny cyan-teal light motes, like phosphorescence
in deep water, drifting almost imperceptibly against a near-black abyss — #14161E at center
fading to #040407 at the edges. The motes drift in a slow, non-repeating, organic pattern,
never accelerating, never clustering abruptly.
```

**变体 C — 眼部意象（呼应护眼主题）**

```text
At the center, a single abstract eye rendered in soft cyan-teal #6BE0CC light, formed only by
diffuse glow with no hard outlines. A faint misty light slowly closes over it and then
gradually lifts away, like an eyelid of light, over the full duration.
```

> 坦白说：变体 C 的可控性最差（模型容易把"眼睛"画成写实眼球，很吓人）。要做就用极抽象的描述，或者干脆用代码画眼睛。我更推荐 A。

---

## 七、校验与后处理（ffmpeg 已装）

### 1. 校验首尾帧是否真的对齐

```bash
cd <输出目录>

# 抽首帧 / 尾帧
ffmpeg -y -i loop.mp4 -vf "select=eq(n\,0)" -vframes 1 /tmp/f_first.png
ffmpeg -y -sseof -0.05 -i loop.mp4 -vframes 1 /tmp/f_last.png

# 比对（SSIM 越接近 1.0 越好）
ffmpeg -i /tmp/f_first.png -i /tmp/f_last.png -lavfi ssim -f null - 2>&1 | tail -2
```

判读：**SSIM ≥ 0.98** 基本肉眼看不出循环点；**≥ 0.995** 可以认为完美。

### 2. 三段闭环拼接

```bash
# 先各自统一编码，再无损拼接
for i in 1 2 3; do
  ffmpeg -y -i part$i.mp4 -c:v libx264 -profile:v high -pix_fmt yuv420p \
         -crf 18 -r 30 -an -movflags +faststart p$i.mp4
done

printf "file 'p1.mp4'\nfile 'p2.mp4'\nfile 'p3.mp4'\n" > list.txt
ffmpeg -y -f concat -safe 0 -i list.txt -c copy rest-loop.mp4
```

### 3. 补救：首尾没完全对上时

如果 SSIM 不理想（比如单段生成路线），把开头 0.6 秒挪到结尾做交叉溶解，制造出天然的对上：

```bash
ffmpeg -y -i raw.mp4 -filter_complex \
"[0:v]split[body][pre];\
 [pre]trim=duration=0.6,setpts=PTS-STARTPTS[head];\
 [body]trim=start=0.6,setpts=PTS-STARTPTS[b];\
 [b][head]xfade=transition=fade:duration=0.6:offset=END_OFFSET[out]" \
-map "[out]" -c:v libx264 -crf 18 -pix_fmt yuv420p -an -movflags +faststart loop.mp4
```

`END_OFFSET` = 主体时长 − 0.6（主体 14.4s → `13.8`）。

### 4. 最终交付编码

```bash
ffmpeg -y -i loop.mp4 -c:v libx264 -profile:v high -level 4.1 \
  -pix_fmt yuv420p -crf 18 -preset slow -r 30 -an \
  -movflags +faststart \
  -vf "scale=1920:1080:flags=lanczos" \
  rest-loop.mp4
```

---

## 八、App 侧接入要点

### 1. 资源与构建

视频放 `Resources/rest-loop.mp4`，`build.sh` 里加一步拷贝（并把 `-framework AVFoundation`、`-framework CoreMedia` 加上）：

```bash
cp "$DIR/rest-loop.mp4" "$RESOURCES_DIR/rest-loop.mp4"
```

### 2. 播放层（加在 BreakOverlay 里）

```swift
import AVFoundation

private var queuePlayer: AVQueuePlayer?
private var looper: AVPlayerLooper?
private var videoLayer: AVPlayerLayer?

private func startLoopVideo(in view: NSView) {
    guard let url = Bundle.main.url(forResource: "rest-loop", withExtension: "mp4") else {
        logDebug("rest-loop.mp4 未找到，跳过循环视频")
        return                      // 兜底：找不到视频就用原来的纯黑背景
    }

    let item = AVPlayerItem(url: url)
    let player = AVQueuePlayer()
    player.isMuted = true

    let layer = AVPlayerLayer(player: player)
    layer.frame = view.bounds
    layer.videoGravity = .resizeAspectFill
    layer.opacity = 0
    view.layer?.addSublayer(layer)

    // 无缝循环：交给 AVPlayerLooper，不要手动 seek
    let lp = AVPlayerLooper(player: player, templateItem: item)
    lp.loopCount = .infinite

    queuePlayer = player
    looper = lp
    videoLayer = layer

    player.play()

    // 与文字淡出重叠的 0.8s 淡入
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    fade.duration = 0.8
    fade.beginTime = CACurrentMediaTime() + 0.3
    fade.fillMode = .backwards
    fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
    layer.add(fade, forKey: "rr.videoFadeIn")
    layer.opacity = 1
}
```

### 3. 淡出与退出

```swift
func stopLoopVideo(animated: Bool = true) {
    guard let layer = videoLayer else { return }
    queuePlayer?.pause()
    if animated {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            layer.opacity = 0
        } completionHandler: { [weak self] in
            layer.removeFromSuperlayer()
            self?.videoLayer = nil
            self?.looper = nil
            self?.queuePlayer = nil
        }
    } else {
        layer.removeFromSuperlayer()
        videoLayer = nil; looper = nil; queuePlayer = nil
    }
}
```

### 4. 退出条件要改（伪熄屏模式下没有真实熄屏事件了）

原来靠 `pendingResetAfterSleep` + 等屏幕亮回来判断"用户回来了"，伪熄屏下屏幕从没黑过，这个条件永远不成立。改成：

```swift
// 伪熄屏下：idle 持续归零 = 用户有动作
var resumeTicks = 0
let resumeGraceTicks = 2      // 连续 2 秒有动作才认，避免误触

// tick() 内
if inRestLoop {
    if PresenceDetector.getIdleSeconds() < 1.0 {
        resumeTicks += 1
        if resumeTicks >= resumeGraceTicks { exitRestLoop() }   // 淡出视频 → 恢复 → 计时清零
    } else {
        resumeTicks = 0
    }
    return
}
```

Esc 退出逻辑保留不变。

---

## 九、成本

用我这边生成的话（需你确认后我才开始）：

| 项目 | 单价 | 数量 | 小计 |
|---|---|---|---|
| 关键帧图（ImageGen） | 约 5–10 credits / 张 | 3 张 | 15–30 |
| 视频段（VideoGen） | 约 50–100 credits / 5 秒 | 3 段 | 150–300 |
| **合计** | | | **约 165–330 credits** |

单段 15 秒路线若模型支持，成本约为 150–300（省掉两张关键帧图的设计迭代）。

---

## 十、验收清单

- [ ] 首尾帧 SSIM ≥ 0.98
- [ ] 时长 15.0s ± 0.1，30fps，无音轨
- [ ] 画面中**没有任何文字**（放大到 200% 检查一遍）
- [ ] 镜头全程静止（在视频中间和首尾各抽一帧，构图应完全一致）
- [ ] 用 `AVPlayerLooper` 连续播 3 分钟，观察循环点不闪黑、不跳变
- [ ] 主屏铺满无黑边；副屏纯黑
- [ ] 文字层叠加后，在视频亮度最高时仍然清晰可读
- [ ] 断网 / 视频文件缺失时，能退回原来的纯黑背景（兜底不能崩）
- [ ] 息屏后动鼠标 1 次不退出（防误触），连续动 2 秒才退出

---

## 附：一句话总结

**首尾帧取同一张图**是这个方案的地基——它把"无缝"从"靠提示词祈祷模型听话"变成"像素级保证"。剩下的只是播放器用 `AVPlayerLooper`、文字交给代码、退出条件从"等屏幕亮回来"改成"连续 2 秒有输入"。
