import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// RestReminder 循环休息影片 · 逐帧渲染器 v2
//
// 相比 v1（三层同心光晕）的差别：
//   1. 加了「花瓣层」—— 12 个径向拉长的柔和光斑沿圆周分布，随呼吸向外绽开。
//      这是 Apple Watch 正念那种「花朵绽开」观感的主要来源。
//   2. 加了「星尘层」—— 二十来个小光点各自绕小轨道缓慢游动。
//   3. 整体亮度大幅提高（核心峰值 alpha 从 0.58 → 0.86）。
//
// 循环无缝的两个保证：
//   · 呼吸曲线 w = 0.5 − 0.5·cos(2πt/15)，两端速度都为 0；
//   · 花瓣在 15 秒内恰好转过 2π/12（正好一个花瓣的间隔）—— 12 个花瓣均匀分布，
//     转 1/12 圈后图案与自身完全重合，所以循环点上花瓣位置也对得上。

// ─────────────────────────── 规格
let W = 1920
let H = 1080
let FPS = 60
let DUR = 15.0
let TOTAL_FRAMES = Int(DUR * Double(FPS))

// ─────────────────────────── 颜色（与 app 一致）
let bgInnerR = 0.078, bgInnerG = 0.086, bgInnerB = 0.118   // #14161E
let bgOuterR = 0.014, bgOuterG = 0.016, bgOuterB = 0.028   // #040407
let tealR = 0.42, tealG = 0.88, tealB = 0.80               // #6BE0CC

let fw = Double(W), fh = Double(H)

let bgCx = 0.5 * fw
let bgCy = 0.48 * fh
let bgMaxR = (fw * fw + fh * fh).squareRoot() * 0.62

// 光晕中心：距顶部 41.5%（对齐 app 的 iconCenter）
// ⚠️ 逐像素循环里的 y 是「距顶部多少行」，不是 CG 用户坐标
let gCx = 0.5 * fw
let gCy = 0.415 * fh

// ─────────────────────────── 固定伪随机（保证每次渲染结果一致）
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 11) / Double(1 << 53)
}

// ─────────────────────────── 花瓣
let N_PETAL = 12
var petalAngle = [Double](repeating: 0, count: N_PETAL)
var petalRelR  = [Double](repeating: 0, count: N_PETAL)   // 距离抖动
var petalSizeJ = [Double](repeating: 0, count: N_PETAL)   // 大小抖动
for i in 0..<N_PETAL {
    petalAngle[i] = Double(i) * 2.0 * Double.pi / Double(N_PETAL)
    petalRelR[i]  = 0.94 + rnd() * 0.12
    petalSizeJ[i] = 0.90 + rnd() * 0.22
}

// ─────────────────────────── 星尘
// 密度刻意压低（18 颗），但每颗更大更亮、边界更清楚 ——
// 要的是「稀疏但可辨认的颗粒」，不是一层细密的噪点。
let N_DUST = 18
var dustRelR  = [Double](repeating: 0, count: N_DUST)
var dustAng   = [Double](repeating: 0, count: N_DUST)
var dustOrbit = [Double](repeating: 0, count: N_DUST)
var dustPhase = [Double](repeating: 0, count: N_DUST)
var dustSize  = [Double](repeating: 0, count: N_DUST)
var dustGain  = [Double](repeating: 0, count: N_DUST)
for i in 0..<N_DUST {
    dustRelR[i]  = 0.28 + rnd() * 1.40         // 0.28 ~ 1.68 倍核心半径
    dustAng[i]   = rnd() * 2.0 * Double.pi
    dustOrbit[i] = 5.0 + rnd() * 14.0          // 各自的小轨道半径（游动幅度大一点，更活）
    dustPhase[i] = rnd() * 2.0 * Double.pi
    dustSize[i]  = 6.5 + rnd() * 8.0
    dustGain[i]  = 0.55 + rnd() * 0.85
}

// ─────────────────────────── 预计算表
var dx2Glow = [Double](repeating: 0, count: W)
var dy2Glow = [Double](repeating: 0, count: H)
var dx2Bg = [Double](repeating: 0, count: W)
var dy2Bg = [Double](repeating: 0, count: H)

for x in 0..<W {
    let dg = Double(x) - gCx
    dx2Glow[x] = dg * dg
    let db = Double(x) - bgCx
    dx2Bg[x] = db * db
}
for y in 0..<H {
    let dg = Double(y) - gCy
    dy2Glow[y] = dg * dg
    let db = Double(y) - bgCy
    dy2Bg[y] = db * db
}

// 背景预渲染一次
var bgBuf = [Float](repeating: 0, count: W * H * 3)
for y in 0..<H {
    let dyb = dy2Bg[y]
    for x in 0..<W {
        let t = min(1.0, (dx2Bg[x] + dyb).squareRoot() / bgMaxR)
        let s = t * t * (3.0 - 2.0 * t)
        let i = (y * W + x) * 3
        bgBuf[i]     = Float(bgInnerR + (bgOuterR - bgInnerR) * s)
        bgBuf[i + 1] = Float(bgInnerG + (bgOuterG - bgInnerG) * s)
        bgBuf[i + 2] = Float(bgInnerB + (bgOuterB - bgInnerB) * s)
    }
}

// 衰减查找表：归一化高斯，t = 1 处恰好为 0，边缘一阶连续
let LUT_N = 2048

func makeLUT(_ k: Double) -> [Double] {
    var lut = [Double](repeating: 0, count: LUT_N + 1)
    let tail = exp(-k * k)
    let inv = 1.0 / (1.0 - tail)
    for i in 0...LUT_N {
        let t = Double(i) / Double(LUT_N)
        lut[i] = (exp(-(t * k) * (t * k)) - tail) * inv
    }
    return lut
}

let lutCore  = makeLUT(1.95)   // 核心光球（衰减略缓，让光能延伸到花瓣区）
let lutHalo  = makeLUT(0.95)   // 外辉光（长尾）
let lutPetal = makeLUT(1.00)   // 花瓣（衰减缓，边缘更弥散）
let lutDust  = makeLUT(2.10)   // 星尘（衰减轻快 → 颗粒边界更清楚，更像「粒子」）

let lutScale = Double(LUT_N)

// ─────────────────────────── 单帧渲染
func renderFrame(time: Double, into buf: inout [UInt8]) {
    let fSeed = Int(time * Double(FPS) * 1000.0)

    let phase = 2.0 * Double.pi * time / DUR
    let w = 0.5 - 0.5 * cos(phase)

    // 核心光球（大幅提亮）
    let rCore = 195.0 + 185.0 * w
    let aCore = 0.44 + 0.42 * w

    // 外辉光：给整幅画面一点氛围，不再是纯黑
    let rHalo = rCore * (2.10 - 0.30 * w)
    let aHalo = 0.050 + 0.045 * w

    // 花瓣：随呼吸向外绽开
    let rPetal = rCore * (0.74 + 0.22 * w)
    let sPetal = rCore * (0.36 + 0.16 * w)
    // 花瓣：只当一层隐约的底纹，不要抢戏 —— 从 0.13+0.20 降下来
    let aPetal = 0.055 + 0.090 * w
    // 径向拉长的椭圆 —— 拉长才像花瓣，正圆只会像一圈珠子。
    // 切向半轴要够大，相邻花瓣才会互相重叠；否则花瓣之间会露出明显的暗隙，
    // 看起来像太阳光芒而不是一朵绽开的花。
    let arP = sPetal
    let atP = sPetal * 0.72
    let invArP = 1.0 / arP
    let invAtP = 1.0 / atP

    // 花瓣整体缓慢转动：15 秒恰好转 2π/12，图案与自身重合，循环点对得上
    let petalSpin = (2.0 * Double.pi / Double(N_PETAL)) * (time / DUR)

    var petalX = [Double](repeating: 0, count: N_PETAL)
    var petalY = [Double](repeating: 0, count: N_PETAL)
    var petalCos = [Double](repeating: 0, count: N_PETAL)
    var petalSin = [Double](repeating: 0, count: N_PETAL)
    for i in 0..<N_PETAL {
        let a = petalAngle[i] + petalSpin
        let ca = cos(a), sa = sin(a)
        petalCos[i] = ca
        petalSin[i] = sa
        let rr = rPetal * petalRelR[i]
        petalX[i] = gCx + rr * ca
        petalY[i] = gCy + rr * sa
    }

    // 星尘：各自绕小轨道游动，周期与呼吸同为 15 秒
    // 星尘：颗数少了，就靠亮度补回来，保证「一眼能看到粒子」
    let aDust = 0.46 + 0.42 * w
    var dustX = [Double](repeating: 0, count: N_DUST)
    var dustY = [Double](repeating: 0, count: N_DUST)
    for i in 0..<N_DUST {
        let baseR = dustRelR[i] * rCore
        let ox = dustOrbit[i] * cos(phase + dustPhase[i])
        let oy = dustOrbit[i] * sin(phase + dustPhase[i])
        dustX[i] = gCx + baseR * cos(dustAng[i]) + ox
        dustY[i] = gCy + baseR * sin(dustAng[i]) + oy
    }

    let invCore = 1.0 / rCore
    let invHalo = 1.0 / rHalo

    buf.withUnsafeMutableBufferPointer { out in
        DispatchQueue.concurrentPerform(iterations: H) { y in
            let dyg = dy2Glow[y]

            // 行级独立 xorshift，避免数据竞争，也比系统 RNG 快得多
            var s: UInt64 = UInt64(truncatingIfNeeded: y) &* 0x9E3779B97F4A7C15
                &+ UInt64(truncatingIfNeeded: Int(fSeed)) &* 0xD1B54A32D192ED03
                &+ 0x243F6A8885A308D3
            let rscale = 1.0 / Double(1 << 53)

            var i = y * W * 3
            for x in 0..<W {
                let dxg = Double(x) - gCx
                let d = (dxg * dxg + dyg).squareRoot()

                var a1 = 0.0
                let t1 = d * invCore
                if t1 < 1.0 { a1 = aCore * lutCore[Int(t1 * lutScale)] }

                var a2 = 0.0
                let t2 = d * invHalo
                if t2 < 1.0 { a2 = aHalo * lutHalo[Int(t2 * lutScale)] }

                // 花瓣：先做廉价的椭圆域判断，命中才细算
                var a3 = 0.0
                let dx = Double(x)
                let dy = Double(y)
                for k in 0..<N_PETAL {
                    let dxp = dx - petalX[k]
                    let dyp = dy - petalY[k]
                    let ar = dxp * petalCos[k] + dyp * petalSin[k]
                    let at = -dxp * petalSin[k] + dyp * petalCos[k]
                    let q = (ar * invArP) * (ar * invArP) + (at * invAtP) * (at * invAtP)
                    if q < 1.0 {
                        a3 += aPetal * petalSizeJ[k] * lutPetal[Int(q.squareRoot() * lutScale)]
                    }
                }
                if a3 > 1.0 { a3 = 1.0 }

                // 星尘：影响半径很小，绝大多数像素第一步就被排掉
                var a4 = 0.0
                for k in 0..<N_DUST {
                    let dxd = dx - dustX[k]
                    let dyd = dy - dustY[k]
                    let sz = dustSize[k]
                    let d2 = dxd * dxd + dyd * dyd
                    if d2 < sz * sz {
                        a4 += aDust * dustGain[k] * lutDust[Int((d2.squareRoot() / sz) * lutScale)]
                    }
                }
                if a4 > 1.0 { a4 = 1.0 }

                // 各层依次叠加的等效 alpha（简单相加会偏亮）
                let alpha = 1.0 - (1.0 - a1) * (1.0 - a2) * (1.0 - a3) * (1.0 - a4)

                // 中心往白里带一点 —— 这是「看着够亮」的关键。
                // 纯青色叠到深底上只会像一层雾；高 alpha 区域趋向白光，
                // 才有「发光核心」的观感（Apple Watch 正念就是白心 + 彩色外缘）。
                var cr = tealR, cg = tealG, cb = tealB
                if alpha > 0.55 {
                    let wh = min(1.0, (alpha - 0.55) / 0.45) * 0.60
                    cr += (1.0 - tealR) * wh
                    cg += (1.0 - tealG) * wh
                    cb += (1.0 - tealB) * wh
                }

                let br = Double(bgBuf[i])
                let bg_ = Double(bgBuf[i + 1])
                let bb = Double(bgBuf[i + 2])

                let r = br + (cr - br) * alpha
                let g = bg_ + (cg - bg_) * alpha
                let b = bb + (cb - bb) * alpha

                s = s &* 6364136223846793005 &+ 1442695040888963407
                let n1 = Double(s >> 11) * rscale
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let n2 = Double(s >> 11) * rscale
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let n3 = Double(s >> 11) * rscale

                out[i]     = UInt8(min(255.0, max(0.0, r * 255.0 + (n1 - 0.5))))
                out[i + 1] = UInt8(min(255.0, max(0.0, g * 255.0 + (n2 - 0.5))))
                out[i + 2] = UInt8(min(255.0, max(0.0, b * 255.0 + (n3 - 0.5))))
                i += 3
            }
        }
    }
}

// ─────────────────────────── 入口
let args = CommandLine.arguments

if args.count >= 4 && args[1] == "--preview" {
    let t = Double(args[2]) ?? 0
    let outPath = args[3]
    var buf = [UInt8](repeating: 0, count: W * H * 3)
    renderFrame(time: t, into: &buf)

    let cs = CGColorSpaceCreateDeviceRGB()
    var rgba = [UInt8](repeating: 255, count: W * H * 4)
    for i in 0..<(W * H) {
        rgba[i * 4]     = buf[i * 3]
        rgba[i * 4 + 1] = buf[i * 3 + 1]
        rgba[i * 4 + 2] = buf[i * 3 + 2]
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let img = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: W * 4, space: cs,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent) else {
        FileHandle.standardError.write("无法创建图像\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outPath)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("无法写入 \(outPath)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("已输出 \(outPath)  (t = \(t)s)")
} else {
    setvbuf(stdout, nil, _IOFBF, 1 << 20)
    var buf = [UInt8](repeating: 0, count: W * H * 3)
    let start = Date()
    for f in 0..<TOTAL_FRAMES {
        let t = Double(f) / Double(FPS)
        renderFrame(time: t, into: &buf)
        fwrite(buf, 1, W * H * 3, stdout)
        if f % 60 == 0 {
            FileHandle.standardError.write("帧 \(f)/\(TOTAL_FRAMES)\n".data(using: .utf8)!)
        }
    }
    fflush(stdout)
    FileHandle.standardError.write(
        "完成 \(TOTAL_FRAMES) 帧，用时 \(String(format: "%.1f", Date().timeIntervalSince(start)))s\n"
            .data(using: .utf8)!)
}
