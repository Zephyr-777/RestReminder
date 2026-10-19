# RestReminder · 循环休息动画：Seedance 生成方案

> 目标：现有「该休息眼睛了」提醒动画播完后，不直接黑屏，而是落进一段 **15 秒无缝循环**的呼吸光晕，
> 直到用户动鼠标或按 Esc 才退出。循环点肉眼看不出接缝。

---

## 一、Seedance 恰好原生支持这件事

Seedance 的首尾帧模式官方说明里有一句关键的话：

> **"May be the same image as the first frame, which produces a seamless loop."**
> （尾帧可以就用首帧那张图，这会直接产生无缝循环）

也就是说，**首帧和尾帧传同一张图**，模型只在中间补运动——循环点两侧像素完全相同，无缝是几何级保证，不是靠提示词祈祷。

而且 Seedance 2.5 支持 **4–30 秒**，一次就能生成 15 秒，不必像通用模型那样分三段拼接。

| 模型 | 时长范围 | 分辨率 | 首尾帧 |
|---|---|---|---|
| Seedance 1.0 lite | 2–12s | 480p/720p | 支持 |
| Seedance 1.5 Pro | 4–12s（-1 自动） | 480p/720p/1080p | 支持 |
| **Seedance 2.0** first-last-frame | 4–15s | **480p/720p/1080p** | 支持，1080p 可用 |
| **Seedance 2.5** first-last-frame | **4–30s** | 480p/720p（部分平台 1080p） | 支持 |

**推荐 Seedance 2.5**（一次 15 秒最省事）；如果平台上的 2.5 只有 720p 而你想要 1080p，改用 **2.0 的 first-last-frame**（正好 15 秒上限、支持 1080p）。

---

## 二、首帧图已经渲染好了

两张图都在 `assets/` 里，配色与位置是**用代码从 `main.swift` 的实际参数里取的**，不是估的：

| 文件 | 用途 | 说明 |
|---|---|---|
| `assets/loop-frame-a-rest.png` | **首帧 + 尾帧（都用它）** | 静息态：光晕半径 300px，中心峰值 alpha 0.24 |
| `assets/loop-frame-c-peak.png` | 仅作参考，不要上传 | 最盛态：光晕半径 460px，峰值 0.36，用来预览「会涨到多大」 |

规格：1920×1080（16:9）、PNG 无损、约 2 MB。

对齐的实际数值：

| 元素 | 值 | 来源 |
|---|---|---|
| 背景径向渐变 | `#14161E` → `#040407` | `BreakOverlay.buildLayers` 的 `bg.colors` |
| 光晕主色 | `#6BE0CC` = srgb(0.42, 0.88, 0.80) | 同上 `glow.colors` |
| 光晕中心 | 水平 50%、距顶部 41.5% | `iconCenter = fromTop(h * 0.415)` |
| 光晕衰减 | 归一化高斯（多段 stop 会有环纹） | 第一版踩过的坑，见文末 |

> 图里带极细微的抖动噪点，用来压制深色渐变的色带。放大看是颗粒，正常。

---

## 三、Seedance 参数（照抄）

| 参数 | 填什么 | 为什么 |
|---|---|---|
| 模式 | **图生视频 · 首尾帧** | 放 2 张图会自动进这个模式；<br>2.5 界面上没有模式按钮，靠附件数量判断 |
| 首帧图 | `loop-frame-a-rest.png` | |
| 尾帧图 | **同一张 `loop-frame-a-rest.png`** | ⚠️ 这是无缝的全部秘密，别换成别的图 |
| 时长 duration | **15** | 秒。2.5 可填 4–30；2.0 上限正好 15 |
| 分辨率 | **1080p 优先**，平台只给 720p 也行 | 这是长时间注视的暗场画面，色带最容易被看出来；<br>1080p 码率更高、色带最少。720p 能省约六成成本 |
| 宽高比 aspect_ratio | **`adaptive`** | 2.5 只有这一个选项，输出**继承首帧比例**——<br>所以首帧图必须已经是 16:9（我给的正是） |
| **声音 generate_audio** | **`false`** | ⚠️ 默认是 **true**，不显式关掉会生成一段音效，<br>循环时很诡异。app 侧也会强制静音，但别浪费这笔钱 |
| 镜头 camera_fixed | v1.x 有，**2.5 没有** | 所以固定镜头只能靠提示词写死，见下 |
| 运镜 | 不要指定任何运镜 | 任何推拉摇移都会让循环崩掉 |

**成本参考**（第三方平台报价，仅供参考，以你实际界面为准）：

- 720p：约 **$0.231/秒** × 15s ≈ **$3.5**
- 1080p：约 **$0.562/秒** × 15s ≈ **$8.4**

---

## 四、提示词

首尾帧模式下，**两端已经被图钉死了，提示词只需要描述中间的运动**——不用再描述画面长什么样。
所以下面这份很短，但每一句都在堵一个具体的坑。

### 中文版（推荐，Seedance 对中文理解最好）

```text
画面的主体是中央一团柔和的冷青色光晕，悬浮在近乎全黑的深色背景上。整段 15 秒只是这团光晕的
一次完整呼吸，画面里没有别的任何东西。

0–5 秒：光晕从静息的小尺寸开始，极其缓慢、匀速地向四周扩张，中心亮度随着变大而柔和上升，
边缘始终完全柔化、不出现清晰轮廓。
5–7 秒：光晕抵达最大最亮的饱满状态，短暂停驻，安静平稳。
7–15 秒：光晕开始缓慢收缩，速度越来越轻缓，最终精确回到开场时的静息大小与亮度，完全静止下来。

镜头完全锁定，固定机位。全程不推、不拉、不摇、不移动、不旋转、不变焦、不改变景深。
光晕的中心位置、背景的颜色与纹理、整体构图自始至终保持绝对一致，不产生任何漂移。
整段只有一次扩张和一次收缩，没有第二个脉冲，没有闪烁，没有速度突变，没有剪辑，
没有任何物体进入或离开画面。

不要文字、字母、数字、字幕、水印、logo、图标。不要出现人物、动物或任何物体。
```

### 英文版（平台只吃英文时用）

```text
A single soft cyan-teal glow floats at the center of a near-black charcoal field. The whole
15 seconds is one complete, slow breath of this single glow, and nothing else appears in frame.

0-5s: the glow begins at its small resting size and expands extremely slowly and evenly outward,
its center brightness rising softly as it grows. Its edge stays fully feathered with no visible outline.
5-7s: the glow settles at its largest, brightest state and holds there, still and calm.
7-15s: the glow contracts gradually, easing off more and more, until it returns exactly to the
resting size and brightness it opened with, coming fully to rest.

Camera completely locked and static — no zoom, no pan, no tilt, no dolly, no rotation,
no focus or depth-of-field change.
The glow's center position, the background color and texture, and the overall framing stay
absolutely unchanged throughout, with no drift.
Exactly one expansion and one contraction. No second pulse, no flicker, no speed change,
no cut, and nothing enters or leaves the frame.

No text, letters, numbers, subtitles, watermarks, logos or icons. No people, animals or objects.
```

### 兜底负向提示词（平台有 negative prompt 字段时才填）

```text
文字, 字幕, 字母, 数字, 水印, logo, 图标, 人物, 人脸, 动物, 物体,
镜头运动, 推拉, 摇移, 旋转, 变焦, 抖动, 剪辑, 转场, 场景切换,
闪烁, 频闪, 亮度突变, 快速运动, 第二个光晕, 镜头光晕, 硬边, 环形纹理, 色带, 噪点, 低画质
```

```text
text, subtitles, letters, words, numbers, watermark, logo, icons, UI,
people, faces, hands, animals, objects,
camera movement, zoom, pan, tilt, rotation, dolly, handheld shake,
cuts, transitions, scene change, strobing, flicker, brightness jump,
fast motion, second glow, lens flare, hard edges, ring artifacts, banding, low quality
```

---

## 五、每句话在堵什么坑

| 提示词里的句子 | 防的是 |
|---|---|
| 「只有一次扩张和一次收缩，没有第二个脉冲」 | 模型爱在长时长里塞进好几个呼吸周期，那样循环节拍就乱了 |
| 「精确回到开场时的静息大小与亮度」 | 收尾时留一点偏差，循环点就会跳一下 |
| 「镜头完全锁定……不改变景深」 | **镜头一动循环必崩**，这是最常见死因。2.5 没有 `camera_fixed` 参数，只能靠这句话 |
| 「边缘始终完全柔化、不出现清晰轮廓」 | 模型会把柔和光晕画成有明确边界的球体或光圈 |
| 「不要文字、字母、数字、字幕」 | AI 生成文字必糊，尤其是中文，而且无法修复。重复两遍不嫌多 |
| 「没有任何物体进入或离开画面」 | 很爱自己加个飘过的粒子、光点 |
| 0–5 / 5–7 / 7–15 的时间分段 | Seedance 2.5 对时间戳分段提示词响应更好，节拍更可控 |

**为什么首尾都落在「静息态」是对的：** 呼吸是周期运动，在极值点速度为 0。
两端都停在静息态，意味着进循环时速度从 0 平滑起步、出循环时速度平滑归零——
不只是位置对上，**运动相位也对上**。位置对上但方向相反的话，循环点会出现「猛地倒回来」的顿挫。

---

## 六、生成完先自查，再放进 app

### 1. 首尾是否真的对上了

```bash
cd <视频所在目录>

ffmpeg -y -i raw.mp4 -vf "select=eq(n\,0)" -vframes 1 /tmp/f_first.png
ffmpeg -y -sseof -0.05 -i raw.mp4 -vframes 1 /tmp/f_last.png

ffmpeg -i /tmp/f_first.png -i /tmp/f_last.png -lavfi ssim -f null - 2>&1 | tail -2
```

判读：

- **SSIM ≥ 0.995** — 完美，直接用
- **0.98 ~ 0.995** — 肉眼基本看不出，可以用
- **< 0.98** — 重新生成（别急着用交叉溶解掩盖，几何/亮度真的变了是藏不住的）

### 2. 顺手确认规格

```bash
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,nb_frames,duration \
  -show_entries format=duration -of default=nw=1 raw.mp4
```

期望：1920×1080、约 24fps、时长 15 秒左右、**没有音频流**。

### 3. 如果带了音轨，去掉

如果生成时忘了关 `generate_audio`：

```bash
ffmpeg -y -i raw.mp4 -c:v copy -an rest-loop.mp4
```

### 4. 统一编码（放进 app 前做一次）

```bash
ffmpeg -y -i rest-loop.mp4 \
  -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p \
  -crf 18 -preset slow -an -movflags +faststart \
  -vf "scale=1920:1080:flags=lanczos" \
  rest-loop.mp4
```

`+faststart` 让首帧起播更快；`-an` 去音轨；`yuv420p` 保证兼容。

---

## 七、接入 app（已实装）

代码侧已经全部改好。你只要把 Seedance 生成的视频重命名为 `rest-loop.mp4` 丢进 `assets/`，跑一次 `./install.sh` 就替换完成：

```
assets/rest-loop.mp4                    ← 换成你的
        ↓  ./install.sh
~/Applications/RestReminder.app/Contents/Resources/rest-loop.mp4
```

### 现在已经有一个可用版本了（逐帧渲染 · 60fps）

`assets/rest-loop.mp4` 不是两张图插值出来的，而是用 `assets/render-breath.swift` **逐帧渲染**的：
1920×1080 / 60fps / 15 秒 / 900 帧，**四层叠加** —— 核心光球 + 12 片花瓣底纹 + 外辉光 + 18 颗星尘。

花瓣只当隐约的底纹（浓度压得很低），并整体缓慢转动（15 秒恰好转 `2π/12`，图案与自身重合，
所以循环点对得上）；星尘颗数少但单颗大而亮，各绕小轨道游动，周期同为 15 秒。
中心在 `alpha > 0.55` 后逐渐趋向白光 —— **白心 + 彩色外缘**才是「发光核心」的观感，
纯青色叠在深底上只会像一层雾。

```bash
swiftc -O -o /tmp/render_breath assets/render-breath.swift
/tmp/render_breath | /opt/homebrew/bin/ffmpeg -y \
  -f rawvideo -pixel_format rgb24 -video_size 1920x1080 -framerate 60 -i - \
  -c:v libx264 -profile:v high -level 4.2 -pix_fmt yuv420p -crf 16 \
  -movflags +faststart assets/rest-loop.mp4
```

实测：900 帧约 12 秒渲完（按行多线程），首尾帧 SSIM **0.9975**，
中心亮度在静息 `(51,94,92)` → 最盛 `(79,160,148)` 之间起伏。
想调呼吸幅度和亮度，改脚本里的 `rCore / aCore / rMid / aMid / rOut / aOut` 那几行。

单帧预览（用来快速试参数）：

```bash
/tmp/render_breath --preview 7.5 /tmp/peak.png    # 7.5 秒 = 呼吸最盛态
/tmp/render_breath --preview 0   /tmp/rest.png    # 0 秒    = 静息态
```

### 更早还有一版 ffmpeg blend 合成的

留作备份在 `assets/rest-loop-v1-blend.mp4`（24fps，SSIM 0.9945）。
做法是把静息态和最盛态两张图按 `A + (B-A) × (1-cos(2πt/15))/2` 混合。
数学上首尾严格相等，但本质上只是两个极端状态之间的线性插值，没有层次变化 —— 所以后来换成了逐帧渲染。

### 想换成 Seedance 生成的

按下面的参数生成，重命名为 `rest-loop.mp4` 放进 `assets/` 覆盖即可。
Seedance 的优势是质感（有机感、颗粒）比纯数学渲染更自然；代价是要花钱，
而且首尾帧一致性得靠它的首尾帧功能来保证，不像自己渲染那样数学上严格相等。

### 已实装的行为

| 部分 | 做法 |
|---|---|
| 播放 | `AVQueuePlayer` + `AVPlayerLooper`，绝不用 `didPlayToEndTime` + seek |
| 层序 | `bg(0) → video(1) → 其余内容层`，影片插在背景之上、内容之下 |
| 衔接 | 进度条走满后：内容层 0.6s 淡出，影片延迟 0.2s、0.8s 淡入（重叠 0.3s） |
| 文字 | 影片不含任何文字；底部提示由 `CATextLayer` 画 |
| 退出 | Esc 立即退；或 idle 连续 2 秒归零（连续计数防误触） |
| 退出后 | 计时清零；从「预览」进来的不清零 |
| 兜底 | 影片缺失 → 菜单项置灰并标注 + 自动退回真熄屏，不崩 |

### 踩到并已修掉的两个坑

1. **`AVPlayerLooper.loopCount` 是只读的**（表示已循环次数），写 `lp.loopCount = .infinite` 编译不过。
   AVPlayerLooper 创建后本来就会一直循环，不需要设置。
2. **淡出内容层前必须 `layer.removeAllAnimations()`**。入场动画用了
   `fillMode = .backwards` + `isRemovedOnCompletion = false`，留在层上的动画会持续把 `opacity` 顶回 1，
   只改模型值会被它盖掉 —— 症状是「淡不出去」。

---

## 八、验收清单

- [ ] 首尾帧 SSIM ≥ 0.98
- [ ] 时长 15.0s ± 0.2，无音频流
- [ ] 画面里**没有任何文字**（放大到 200% 扫一遍）
- [ ] 镜头全程静止（首帧、中段、尾帧抽三帧，构图完全一致）
- [ ] `AVPlayerLooper` 连播 3 分钟，循环点不闪黑、不跳变
- [ ] 主屏铺满无黑边，副屏纯黑
- [ ] 文字层叠上去后，在光晕最亮时仍清晰可读
- [ ] 视频文件缺失时能退回原来的纯黑背景，不崩
- [ ] 息屏后动一下鼠标不退出，连续动 2 秒才退出

---

## 附一：关于深色渐变的色带（banding）

这是渲染首帧图时踩到的坑，值得记一下。

第一版用 `CGGradient` 的分段 stop 近似光晕，结果出现**明显的同心环纹**。
原因是：光晕峰值到背景之间，RGB 总共只有约 20~55 个色阶可用，
分段线性插值必然在每一级台阶上留下可见的圆环。

改成两件事就好了：

1. **逐像素计算归一化高斯衰减**，而不是分段线性：
   `glow = peak * (exp(-(t·k)²) - exp(-k²)) / (1 - exp(-k²))`，其中 `t = 距离/半径`，`k = 1.8`。
   这个式子保证在 `t = 1` 处恰好衰减到 0，边缘一阶连续。
2. **量化前加抖动**：每个通道在取整前加一个 `[0,1)` 的随机偏移。

## 附二：另一个坑——逐像素循环里的 y 是从顶部算的

`CGContext` 的坐标原点在左下，但它的 `data` 缓冲区**第 0 行对应图像顶部**。

所以逐像素循环 `for y in 0..<H` 里的 `y` 是「距顶部多少行」，
如果直接拿它当 CG 用户坐标用，整个画面会上下颠倒。

实测症状：光晕本该落在距顶部 41.5%，却跑到了 58.1%（≈ 100% − 41.5%）。
渲染完一定要抽最亮像素验证一下位置，别靠肉眼——柔和光晕的视觉重心不可靠。
