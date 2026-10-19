#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RestReminder 每日播报生成器

数据来源（按优先级合并）：
  1. ~/Library/Application Support/RestReminder/stats/YYYY-MM-DD.json
     新版 app 实时记账，精确到秒。
  2. debug.log 回溯估算 —— 只在 1 缺失、或与 1 同一小时互补时使用。
     老日志只有「在场状态切换」这类事件，时长靠相邻事件的间隔推算，所以是估算。

输出：reports/YYYY-MM-DD.html（单文件，无外链，可离线打开）

用法：
  python3 daily_report.py                    # 今天
  python3 daily_report.py --date 2026-10-18  # 指定日期
  python3 daily_report.py --days 30          # 趋势窗口
"""

import argparse
import datetime as dt
import json
import math
import re
import subprocess
import sys
from pathlib import Path

# ---------- 路径 ----------

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/RestReminder"
STATS_DIR = SUPPORT / "stats"
OUT_DIR = SUPPORT / "reports"

# 旧日志回溯是给「装了新版但那天还没有 stats 文件」的日期兜底的。
# 新版日志写在 ~/Library/Logs，老版本写在源码目录，两个位置都找一下。
PROJECT = Path(__file__).resolve().parent.parent
_LOG_CANDIDATES = [
    HOME / "Library/Logs/RestReminder/debug.log",
    PROJECT / "debug.log",
]
LOG_PATH = next((p for p in _LOG_CANDIDATES if p.exists()), _LOG_CANDIDATES[0])

WEEKDAY_CN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


# ---------- 格式化 ----------

def fmt_hm(seconds):
    """秒 → 3小时12分 / 47分钟 / 18秒"""
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}秒"
    h, m = divmod(seconds // 60, 60)
    if h == 0:
        return f"{m}分钟"
    if m == 0:
        return f"{h}小时"
    return f"{h}小时{m}分"


def fmt_hm_short(seconds):
    h = seconds / 3600
    return f"{h:.1f}"


def hhmm(text):
    return text or "--:--"


def pct(part, whole, digits=0):
    if not whole:
        return 0.0
    return round(part / whole * 100, digits)


# ---------- 数据：老日志回溯 ----------

EVENT_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \+0000: (.*)$")


def blank_day(date_key):
    return {
        "date": date_key,
        "screen": 0,
        "away": 0,
        "paused": 0,
        "micro_t": 0, "micro_c": 0, "micro_rest": 0,
        "long_t": 0, "long_c": 0, "long_rest": 0,
        "hourly_screen": [0] * 24,
        "hourly_breaks": [0] * 24,
        "first": None, "last": None,
        "longest": 0, "sessions": 0,
        "source": "none",
    }


def parse_log():
    """把 debug.log 还原成「每天大概用了多久」。

    只认这几类事件，其余行忽略：
      · 在场判定: focusing → watching / watching → focusing / … → away(...)
      · 触发微休息全屏提醒 / 微休息结束
      · 进入循环休息画面 / 循环休息画面结束
      · 转等待唤醒 / 从熄屏唤醒
    两事件之间的间隔按当时的状态归属。单个间隔封顶 60 分钟，
    防止一觉睡到早上被算成连续用眼。
    """
    if not LOG_PATH.exists():
        return {}

    local_tz = dt.datetime.now().astimezone().tzinfo
    events = []
    for line in LOG_PATH.read_text(encoding="utf-8", errors="replace").splitlines():
        if "旧日志行" in line:
            continue
        m = EVENT_RE.match(line)
        if not m:
            continue
        ts = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        ts = ts.replace(tzinfo=dt.timezone.utc).astimezone(local_tz)
        events.append((ts, m.group(2)))

    if not events:
        return {}

    events.sort(key=lambda e: e[0])

    days = {}
    state = "focusing"
    prev_ts = None
    session_run = 0

    for ts, msg in events:
        if prev_ts is not None:
            gap = (ts - prev_ts).total_seconds()
            if gap > 0:
                gap = min(gap, 3600)
                key = prev_ts.strftime("%Y-%m-%d")
                d = days.setdefault(key, blank_day(key))
                hour = prev_ts.hour

                if state in ("focusing", "watching"):
                    d["screen"] += gap
                    d["hourly_screen"][hour] += int(gap)
                    session_run += gap
                    d["longest"] = max(d["longest"], int(session_run))
                    if d["first"] is None:
                        d["first"] = prev_ts.strftime("%H:%M")
                    d["last"] = prev_ts.strftime("%H:%M")
                elif state == "micro":
                    d["micro_rest"] += int(gap)
                elif state == "long":
                    d["long_rest"] += int(gap)
                elif state in ("away", "paused"):
                    d["away"] += int(gap)

        if "在场判定" in msg:
            prev_state = state
            state = "away" if "away" in msg else msg.split("→ ")[1].split(" ")[0]
            if state in ("focusing", "watching") and prev_ts is not None:
                if prev_state not in ("focusing", "watching"):
                    key = ts.strftime("%Y-%m-%d")
                    days.setdefault(key, blank_day(key))["sessions"] += 1
        elif "触发微休息" in msg:
            state = "micro"
            key = ts.strftime("%Y-%m-%d")
            d = days.setdefault(key, blank_day(key))
            d["micro_t"] += 1
            d["hourly_breaks"][ts.hour] += 1
        elif "微休息结束" in msg:
            state = "focusing"
            key = ts.strftime("%Y-%m-%d")
            d = days.setdefault(key, blank_day(key))
            if "自然完成=true" in msg:
                d["micro_c"] += 1
        elif "进入循环休息画面" in msg:
            state = "long"
            key = ts.strftime("%Y-%m-%d")
            d = days.setdefault(key, blank_day(key))
            d["long_t"] += 1
            d["hourly_breaks"][ts.hour] += 1
        elif "循环休息画面结束" in msg:
            state = "focusing"
            key = ts.strftime("%Y-%m-%d")
            d = days.setdefault(key, blank_day(key))
            d["long_c"] += 1
        elif "转入等待唤醒" in msg:
            state = "away"
        elif "唤醒，大休与微休计时自动重置" in msg:
            state = "focusing"
        elif "判定已休息，计时清零" in msg:
            state = "away"

        # 离开屏幕/进入休息就断掉这一「连续用眼」段
        if state not in ("focusing", "watching"):
            session_run = 0

        prev_ts = ts

    for d in days.values():
        d["source"] = "log"
    return days


# ---------- 数据：新版实时统计 ----------

def read_stats(date_key):
    path = STATS_DIR / f"{date_key}.json"
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None

    d = blank_day(date_key)
    d["screen"] = int(raw.get("screenSeconds", 0))
    d["away"] = int(raw.get("awaySeconds", 0))
    d["paused"] = int(raw.get("pausedSeconds", 0))
    d["micro_t"] = int(raw.get("microTriggered", 0))
    d["micro_c"] = int(raw.get("microCompleted", 0))
    d["micro_rest"] = int(raw.get("microRestSeconds", 0))
    d["long_t"] = int(raw.get("longTriggered", 0))
    d["long_c"] = int(raw.get("longCompleted", 0))
    d["long_rest"] = int(raw.get("longRestSeconds", 0))
    hs = raw.get("hourlyScreen") or []
    hb = raw.get("hourlyBreaks") or []
    d["hourly_screen"] = [int(x) for x in hs][:24] + [0] * (24 - len(hs[:24]))
    d["hourly_breaks"] = [int(x) for x in hb][:24] + [0] * (24 - len(hb[:24]))
    d["first"] = raw.get("firstScreenAt")
    d["last"] = raw.get("lastScreenAt")
    d["longest"] = int(raw.get("longestSessionSeconds", 0))
    d["sessions"] = int(raw.get("sessionCount", 0))
    d["source"] = "real" if d["screen"] > 0 else "none"
    return d


def merge(real, est):
    """同一个小时里两份数据各测了一部分，取较大值 —— 相加会重复计。"""
    if real is None:
        return est
    if est is None:
        return real
    if real["screen"] == 0:
        return est

    m = dict(real)
    m["hourly_screen"] = [max(a, b) for a, b in zip(real["hourly_screen"], est["hourly_screen"])]
    m["screen"] = sum(m["hourly_screen"])
    m["hourly_breaks"] = [max(a, b) for a, b in zip(real["hourly_breaks"], est["hourly_breaks"])]
    m["micro_t"] = max(real["micro_t"], est["micro_t"])
    m["micro_c"] = max(real["micro_c"], est["micro_c"])
    m["micro_rest"] = max(real["micro_rest"], est["micro_rest"])
    m["long_t"] = max(real["long_t"], est["long_t"])
    m["long_c"] = max(real["long_c"], est["long_c"])
    m["long_rest"] = max(real["long_rest"], est["long_rest"])
    m["longest"] = max(real["longest"], est["longest"])
    m["sessions"] = max(real["sessions"], est["sessions"])
    m["away"] = max(real["away"], est["away"])
    m["paused"] = max(real["paused"], est["paused"])
    m["first"] = min(filter(None, [real["first"], est["first"]]), default=None)
    m["last"] = max(filter(None, [real["last"], est["last"]]), default=None)
    m["source"] = "mixed"
    return m


# ---------- 派生指标 ----------

def derive(d):
    screen = d["screen"]
    rest = d["micro_rest"] + d["long_rest"]
    away = d["away"]

    breaks_triggered = d["micro_t"] + d["long_t"]
    breaks_done = d["micro_c"] + d["long_c"]
    compliance = pct(breaks_done, breaks_triggered) if breaks_triggered else None

    sessions = max(d["sessions"], 1)
    longest = d["longest"]
    # 日志回溯出来的 sessions 常偏少（事件稀疏），
    # 用「总时长 / 最长一段」反推一个下限，避免算出「平均 76 分钟、最长 13 分钟」这种自相矛盾
    if longest > 0 and screen > longest:
        sessions = max(sessions, math.ceil(screen / longest))
    avg_session = screen / sessions if screen else 0

    night = sum(d["hourly_screen"][22:24]) + sum(d["hourly_screen"][0:6])
    active_span = screen + rest + away

    # 眼疲劳风险指数（0~100，越高越需要警惕）
    s_time = min(screen / 3600 / 6, 1.0) * 30          # 单日总用眼：6 小时封顶
    s_streak = min(longest / 60 / 45, 1.0) * 25        # 最长连续用眼：45 分钟封顶
    if compliance is None:
        s_rest = 12                                        # 没有休息数据，按中等缺口服
    else:
        s_rest = (1 - compliance / 100) * 25
    s_night = min(night / 3600, 1.0) * 20              # 22:00 后 / 06:00 前
    score = round(s_time + s_streak + s_rest + s_night)

    if score < 25:
        grade, color, verdict = "优秀", "#34a853", "眼睛今天被照顾得很好，保持这个节奏。"
    elif score < 45:
        grade, color, verdict = "良好", "#4285f4", "整体健康，仍有提升空间。"
    elif score < 70:
        grade, color, verdict = "需注意", "#f9ab00", "连续用眼偏长，建议主动打断。"
    else:
        grade, color, verdict = "偏疲劳", "#ea4335", "今天眼睛压力较大，尽快补一次长休息。"

    return {
        "screen": screen, "rest": rest, "away": away,
        "micro_rest": d["micro_rest"], "long_rest": d["long_rest"],
        "micro_t": d["micro_t"], "micro_c": d["micro_c"],
        "long_t": d["long_t"], "long_c": d["long_c"],
        "breaks_triggered": breaks_triggered, "breaks_done": breaks_done,
        "compliance": compliance,
        "avg_session": avg_session, "longest": longest,
        "sessions": sessions, "night": night,
        "score": score, "grade": grade, "color": color, "verdict": verdict,
        "parts": [
            ("总用眼时长", s_time, 30, f"{fmt_hm(screen)} / 6 小时基准"),
            ("最长连续用眼", s_streak, 25, fmt_hm(longest)),
            ("休息缺口", s_rest, 25,
             f"达成率 {int(round(compliance))}%" if compliance is not None else "无休息记录"),
            ("夜间用眼", s_night, 20, fmt_hm(night)),
        ],
        "active_span": active_span,
    }


# ---------- SVG 组件 ----------

def donut(segments, size=232, thickness=28):
    """rings segments: [(label, seconds, color)]"""
    total = sum(s for _, s, _ in segments) or 1
    r = (size - thickness) / 2
    c = 2 * math.pi * r
    cx = cy = size / 2

    out = [
        f'<svg viewBox="0 0 {size} {size}" width="100%" role="img" aria-label="时间构成">',
        f'<circle cx="{cx}" cy="{cy}" r="{r:.2f}" fill="none" stroke="#eef1f5" stroke-width="{thickness}"/>',
    ]
    offset = 0.0
    for label, secs, color in segments:
        if secs <= 0:
            continue
        frac = secs / total
        length = frac * c
        gap = 3.0 if length > 8 else 0.0
        draw = max(length - gap, 0.8)
        out.append(
            f'<circle cx="{cx}" cy="{cy}" r="{r:.2f}" fill="none" stroke="{color}" '
            f'stroke-width="{thickness}" '
            f'stroke-dasharray="{draw:.2f} {c - draw:.2f}" '
            f'stroke-dashoffset="{-offset:.2f}" '
            f'transform="rotate(-90 {cx} {cy})">'
            f'<title>{label} {fmt_hm(secs)}</title></circle>'
        )
        offset += length
    out.append("</svg>")
    return "".join(out)


def bars24(hourly, height=210):
    """24 小时用眼柱状图，颜色按强度分五档（Google 蓝系）。"""
    W, H = 760, height
    pad_l, pad_b, pad_t = 34, 26, 12
    inner_w = W - pad_l - 6
    inner_h = H - pad_b - pad_t
    slot = inner_w / 24
    bar_w = slot * 0.56

    peak = max(max(hourly), 15 * 60)
    # 向上取整到 15 分钟，避免刻度出现 47m 这种数字
    peak = math.ceil(peak / 900) * 900

    steps = [60, 180, 300, 600, 1200, 1800, 2700, 3600, 5400]
    shades = ["#c9dcfb", "#a8c7fa", "#7aabf7", "#4f8df5", "#1a73e8", "#1557b0"]

    def color_of(v):
        ratio = v / peak
        idx = min(len(shades) - 1, int(ratio * (len(shades) - 1) + 0.35))
        return shades[idx]

    out = [f'<svg viewBox="0 0 {W} {H}" width="100%" role="img" aria-label="每小时用眼时长">']

    # 网格 + 左侧刻度
    for i in range(4):
        gy = pad_t + inner_h * i / 3
        val = peak * (1 - i / 3)
        out.append(f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{W - 6}" y2="{gy:.1f}" stroke="#eef1f5" stroke-width="1"/>')
        out.append(
            f'<text x="{pad_l - 8}" y="{gy + 4:.1f}" text-anchor="end" '
            f'font-size="11" fill="#9aa0a6">{int(round(val / 60))}m</text>'
        )

    for h, v in enumerate(hourly):
        x = pad_l + h * slot + (slot - bar_w) / 2
        bh = 0 if v <= 0 else max(3.0, inner_h * v / peak)
        y = pad_t + inner_h - bh
        out.append(
            f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_w:.1f}" height="{bh:.1f}" rx="5" '
            f'fill="{color_of(v) if v > 0 else "#eef1f5"}">'
            f'<title>{h:02d}:00 — {fmt_hm(v)}</title></rect>'
        )
        if h % 3 == 0:
            out.append(
                f'<text x="{x + bar_w / 2:.1f}" y="{H - 8}" text-anchor="middle" '
                f'font-size="11" fill="#9aa0a6">{h}</text>'
            )

    out.append("</svg>")
    return "".join(out)


def trend_chart(points, width=760, height=230):
    """points: [(label, hours, is_real)]"""
    W, H = width, height
    pad_l, pad_r, pad_b, pad_t = 34, 12, 28, 14
    inner_w = W - pad_l - pad_r
    inner_h = H - pad_t - pad_b

    vals = [h for _, h, _ in points]
    peak = max(vals + [1]) * 1.25
    n = len(points)
    step = inner_w / max(n - 1, 1)

    def px(i):
        return pad_l + i * step

    def py(v):
        return pad_t + inner_h - inner_h * (v / peak)

    out = [f'<svg viewBox="0 0 {W} {H}" width="100%" role="img" aria-label="用眼时长趋势">',
           '<defs><linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">'
           '<stop offset="0%" stop-color="#1a73e8" stop-opacity="0.22"/>'
           '<stop offset="100%" stop-color="#1a73e8" stop-opacity="0"/></linearGradient></defs>']

    for i in range(4):
        gy = pad_t + inner_h * i / 3
        val = peak * (1 - i / 3)
        out.append(f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{W - pad_r}" y2="{gy:.1f}" stroke="#eef1f5"/>')
        out.append(f'<text x="{pad_l - 8}" y="{gy + 4:.1f}" text-anchor="end" font-size="11" fill="#9aa0a6">{val:.0f}h</text>')

    line = " ".join(f"{px(i):.1f},{py(v):.1f}" for i, (_, v, _) in enumerate(points))
    area = f"{pad_l},{pad_t + inner_h} " + line + f" {px(n - 1):.1f},{pad_t + inner_h}"
    out.append(f'<polygon points="{area}" fill="url(#areaGrad)"/>')
    out.append(f'<polyline points="{line}" fill="none" stroke="#1a73e8" stroke-width="2.5" '
               f'stroke-linejoin="round" stroke-linecap="round"/>')

    for i, (label, v, is_real) in enumerate(points):
        fill = "#1a73e8" if is_real else "#ffffff"
        stroke = "#1a73e8" if is_real else "#a8c7fa"
        rr = 5.5 if i == n - 1 else 4
        out.append(
            f'<circle cx="{px(i):.1f}" cy="{py(v):.1f}" r="{rr}" fill="{fill}" '
            f'stroke="{stroke}" stroke-width="2"><title>{label} {v:.2f} 小时'
            f'{"（实测）" if is_real else "（日志估算）"}</title></circle>'
        )
        if n <= 16 or i % 2 == 0 or i == n - 1:
            out.append(f'<text x="{px(i):.1f}" y="{H - 8}" text-anchor="middle" font-size="10.5" '
                       f'fill="#9aa0a6">{label}</text>')

    out.append("</svg>")
    return "".join(out)


def gauge(score, color, size=210):
    """半圆仪表盘"""
    W, H = size, size * 0.66
    cx, cy = W / 2, H - 12
    r = W / 2 - 20
    thickness = 16

    def arc(start_deg, end_deg, stroke, width=thickness, opacity=1.0):
        a1 = math.radians(start_deg)
        a2 = math.radians(end_deg)
        x1, y1 = cx + r * math.cos(a1), cy - r * math.sin(a1)
        x2, y2 = cx + r * math.cos(a2), cy - r * math.sin(a2)
        large = 1 if abs(end_deg - start_deg) > 180 else 0
        return (f'<path d="M {x1:.2f} {y1:.2f} A {r} {r} 0 {large} 0 {x2:.2f} {y2:.2f}" '
                f'fill="none" stroke="{stroke}" stroke-width="{width}" stroke-linecap="round" '
                f'opacity="{opacity}"/>')

    ang = 180 * (1 - min(max(score, 0), 100) / 100)
    out = [f'<svg viewBox="0 0 {W} {H + 16}" width="100%" role="img" aria-label="眼疲劳风险指数">']
    out.append(arc(180, 0, "#eef1f5", width=thickness + 2))
    if ang < 179.6:
        out.append(arc(180, ang, color, width=thickness + 2))
    # 两端刻度，让「弧有多长」在视觉上有基准
    out.append(f'<text x="{cx - r - 4}" y="{cy + 16}" text-anchor="middle" font-size="11" fill="#9aa0a6">0</text>')
    out.append(f'<text x="{cx + r + 4}" y="{cy + 16}" text-anchor="middle" font-size="11" fill="#9aa0a6">100</text>')
    out.append(f'<text x="{cx}" y="{cy - 38}" text-anchor="middle" font-size="40" '
               f'font-weight="600" fill="#202124">{score}</text>')
    out.append(f'<text x="{cx}" y="{cy - 16}" text-anchor="middle" font-size="12" fill="#5f6368">眼疲劳风险指数</text>')
    out.append("</svg>")
    return "".join(out)


# ---------- 样式 ----------

CSS = """
:root{
  --blue:#1a73e8; --blue-d:#1557b0; --green:#34a853; --yellow:#f9ab00;
  --red:#ea4335; --ink:#202124; --ink-2:#5f6368; --ink-3:#80868b;
  --line:#e8eaed; --bg:#f8f9fa; --card:#ffffff;
  --shadow-1:0 1px 2px rgba(60,64,67,.16),0 1px 3px 1px rgba(60,64,67,.08);
  --shadow-2:0 1px 3px rgba(60,64,67,.14),0 4px 12px 2px rgba(60,64,67,.10);
  --r-lg:28px; --r-md:18px;
}
*{box-sizing:border-box;-webkit-font-smoothing:antialiased}
body{
  margin:0;background:var(--bg);color:var(--ink);
  font-family:'Google Sans','Google Sans Text',Roboto,'Helvetica Neue',
    -apple-system,BlinkMacSystemFont,'PingFang SC','Hiragino Sans GB',
    'Microsoft YaHei',sans-serif;
  font-size:14px;line-height:1.55;
}
.wrap{max-width:1120px;margin:0 auto;padding:40px 24px 72px}

/* 顶部 */
.hero{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;
  flex-wrap:wrap;margin-bottom:28px}
.hero h1{font-size:34px;line-height:1.2;font-weight:400;margin:0 0 6px;
  letter-spacing:-.6px}
.hero h1 b{font-weight:600}
.hero .sub{color:var(--ink-2);font-size:14px}
.stripe{display:flex;gap:4px;margin-top:14px}
.stripe i{height:4px;border-radius:2px;display:block}
.stripe i:nth-child(1){width:52px;background:#4285f4}
.stripe i:nth-child(2){width:34px;background:#ea4335}
.stripe i:nth-child(3){width:34px;background:#fbbc04}
.stripe i:nth-child(4){width:34px;background:#34a853}
.badge{display:inline-flex;align-items:center;gap:6px;background:#e8f0fe;color:#1967d2;
  border-radius:100px;padding:6px 14px;font-size:12.5px;font-weight:500}

/* 卡片 */
.card{background:var(--card);border-radius:var(--r-lg);box-shadow:var(--shadow-1);
  padding:26px 28px;margin-bottom:20px}
.card.tight{padding:22px 24px}
.sec-head{display:flex;align-items:center;gap:10px;margin:34px 0 14px}
.sec-head .dot{width:10px;height:10px;border-radius:50%}
.sec-head h2{font-size:19px;font-weight:600;margin:0;letter-spacing:-.2px}
.sec-head .hint{color:var(--ink-3);font-size:12.5px;margin-left:auto}

.grid{display:grid;gap:20px}
.g3{grid-template-columns:repeat(3,1fr)}
.g2{grid-template-columns:1.15fr .85fr}
.g-kpi{grid-template-columns:repeat(4,1fr)}
@media(max-width:900px){.g3,.g2,.g-kpi{grid-template-columns:1fr 1fr}}
@media(max-width:620px){.g3,.g2,.g-kpi{grid-template-columns:1fr}}

/* KPI */
.kpi{background:var(--card);border-radius:var(--r-md);box-shadow:var(--shadow-1);
  padding:20px 22px;display:flex;flex-direction:column;gap:6px}
.kpi .label{font-size:12.5px;color:var(--ink-2);display:flex;align-items:center;gap:6px}
.kpi .value{font-size:31px;font-weight:500;letter-spacing:-1px;line-height:1.1}
.kpi .unit{font-size:14px;font-weight:400;color:var(--ink-3);margin-left:2px}
.kpi .foot{font-size:12px;color:var(--ink-3)}
.chip{display:inline-block;font-size:11.5px;padding:2px 9px;border-radius:100px;
  background:#f1f3f4;color:var(--ink-2);font-weight:500}
.chip.green{background:#e6f4ea;color:#137333}
.chip.blue{background:#e8f0fe;color:#1967d2}
.chip.yellow{background:#fef7e0;color:#b06000}
.chip.red{background:#fce8e6;color:#c5221f}

/* 图例 */
.legend{display:flex;flex-direction:column;gap:12px;justify-content:center}
.legend .row{display:flex;align-items:center;gap:10px;font-size:13.5px}
.legend .sw{width:11px;height:11px;border-radius:3px;flex:none}
.legend .val{margin-left:auto;font-variant-numeric:tabular-nums;color:var(--ink-2)}
.legend .val b{color:var(--ink);font-weight:600}

/* 进度条 */
.bar-row{margin-bottom:16px}
.bar-row .top{display:flex;justify-content:space-between;font-size:13px;margin-bottom:7px}
.bar-row .top .n{color:var(--ink-2)}
.track{height:9px;border-radius:100px;background:#eef1f5;overflow:hidden;display:flex}
.track i{display:block;height:100%;border-radius:100px}

/* 明细行 */
.rows .r{display:grid;grid-template-columns:104px 1fr 74px;gap:14px;align-items:center;
  padding:9px 0;border-bottom:1px solid #f4f5f7;font-size:13px}
.rows .r:last-child{border-bottom:none}
.rows .r .k{color:var(--ink-2)}
.rows .r .v{text-align:right;font-variant-numeric:tabular-nums;font-weight:500}

.note{font-size:12.5px;color:var(--ink-3);margin-top:12px;line-height:1.6}
.verdict{display:flex;gap:14px;align-items:flex-start;background:#f8f9fa;
  border-radius:var(--r-md);padding:16px 18px;margin-top:6px}
.verdict .ico{width:34px;height:34px;border-radius:50%;flex:none;display:flex;
  align-items:center;justify-content:center;font-size:17px}
.verdict p{margin:0;font-size:13.5px;color:var(--ink-2)}
.verdict b{color:var(--ink)}
.cmp{margin-bottom:20px}
.cmp:last-child{margin-bottom:4px}
.cmp .t{display:flex;justify-content:space-between;align-items:baseline;font-size:13px;margin-bottom:8px}
.cmp .t .n{color:var(--ink-2);font-size:12.5px}
.cmp .t .n b{color:var(--ink);font-weight:600}
.cmp .track{margin-top:5px;height:8px}
.cmp .cap{font-size:11.5px;color:var(--ink-3);margin-top:9px;display:flex;gap:16px}
.cmp .cap span{display:flex;align-items:center;gap:5px}
.cmp .cap i{width:8px;height:8px;border-radius:2px;display:inline-block}
.app-row{display:grid;grid-template-columns:124px 1fr 82px 44px;gap:12px;align-items:center;
  padding:8px 0;font-size:13px}
.app-row .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.app-row .bar{height:9px;border-radius:100px;background:#f1f3f4;overflow:hidden;display:block}
.app-row .bar i{display:block;height:100%;border-radius:100px}
.app-row .tm{text-align:right;font-variant-numeric:tabular-nums;color:var(--ink-2);font-size:12.5px}
.app-row .pc{text-align:right;color:var(--ink-3);font-size:12px;font-variant-numeric:tabular-nums}
footer{color:var(--ink-3);font-size:12px;text-align:center;margin-top:36px;line-height:1.8}
"""


# ---------- 页面 ----------

SCREENTIME_DIR = HOME / "Library/Application Support/RestReminder/screentime"


def refresh_screentime(date_key, max_age_min=15):
    """当天数据一直在变，导出文件太旧就重跑一次读取器；历史日期不再刷新。

    没授权、库被锁、脚本缺失都静默跳过 —— 卡片自己会显示「没读到」的提示，
    不能因为这一块挂掉整份播报。
    """
    if date_key != dt.date.today().isoformat():
        return
    out = SCREENTIME_DIR / f"{date_key}.json"
    try:
        if out.exists():
            age = (dt.datetime.now().timestamp() - out.stat().st_mtime) / 60
            if age < max_age_min:
                return
    except OSError:
        pass

    script = Path(__file__).with_name("screentime.py")
    if not script.exists():
        return
    try:
        subprocess.run([sys.executable, str(script), "--date", date_key],
                       capture_output=True, timeout=60,
                       cwd=str(Path(__file__).resolve().parent))
    except (subprocess.SubprocessError, OSError):
        pass


def read_screentime(date_key):
    """Apple 自带「屏幕使用时间」的导出文件；没有就返回 None。"""
    path = SCREENTIME_DIR / f"{date_key}.json"
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not raw.get("totalSeconds"):
        return None
    return raw


def screentime_block(st, day=None):
    if not st:
        return """
    <div class="note" style="display:flex;gap:10px;align-items:flex-start">
      <span>ℹ️</span>
      <span>没读到 Apple 自身的屏幕使用时间数据。<br/>
      运行 <code style="background:#f1f3f4;padding:2px 6px;border-radius:4px">python3 tools/screentime.py</code>
      并在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里给 WorkBuddy 授权，即可显示分应用明细。</span>
    </div>"""

    total = st["totalSeconds"]
    apps = st.get("apps", [])[:6]
    peak = max((a["seconds"] for a in apps), default=1)
    shades = ["#1a73e8", "#4285f4", "#669df6", "#8ab4f8", "#aecbfa", "#c9dcfb"]

    rows = ""
    for i, app in enumerate(apps):
        w = app["seconds"] / peak * 100
        rows += f"""
        <div class="app-row">
          <span class="nm" title="{app['bundle']}">{app['name']}</span>
          <span class="bar"><i style="width:{w:.0f}%;background:{shades[min(i, 5)]}"></i></span>
          <span class="tm">{fmt_hm(app['seconds'])}</span>
          <span class="pc">{int(round(pct(app['seconds'], total)))}%</span>
        </div>"""

    meta = []
    if st.get("appCount"):
        meta.append(f"{st['appCount']} 个应用")
    if st.get("switches"):
        meta.append(f"切换 {st['switches']} 次")
    if st.get("unlocks"):
        meta.append(f"解锁 {st['unlocks']} 次")
    if st.get("firstUnlock"):
        meta.append(f"首次解锁 {st['firstUnlock']}")
    meta_txt = " · ".join(meta)

    # 两个口径并排：Apple 分应用前台累加 vs 本工具在场判定
    compare = ""
    if day and day.get("screen"):
        ours = day["screen"]
        diff = total - ours
        gap_ratio = abs(diff) / ours * 100 if ours else 0
        if gap_ratio < 8:
            judge, tint = "两个口径基本吻合", "#188038"
        elif diff < 0:
            judge, tint = "本工具算得更多（含盯着屏幕没操作的时间）", "#b06000"
        else:
            judge, tint = "Apple 算得更多（分应用前台累加更细）", "#b06000"
        compare = f"""
    <div style="display:flex;gap:12px;align-items:center;margin:12px 0 2px;border-top:1px solid #eef1f5;padding-top:14px">
      <div style="font-size:11.5px;color:var(--ink-3);letter-spacing:.4px">本工具口径</div>
      <div style="font-size:15px;font-weight:500;color:var(--ink-2)">{fmt_hm(int(ours))}</div>
      <div style="flex:1;text-align:right;font-size:12px;color:{tint}">{judge}</div>
    </div>"""

    return f"""
    <div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:6px;flex-wrap:wrap;gap:8px">
      <div style="font-size:13px;color:var(--ink-2)">Apple 屏幕使用时间 · 分应用明细</div>
      <div style="font-size:12px;color:var(--ink-3)">{meta_txt}</div>
    </div>
    <div style="display:flex;align-items:baseline;gap:8px">
      <span style="font-size:30px;font-weight:500;letter-spacing:-1px">{total/3600:.1f}</span>
      <span style="font-size:14px;color:var(--ink-3)">小时 · 系统口径</span>
    </div>
    {compare}
    <div style="margin-top:14px">{rows}</div>
    <div class="note">数据来自 macOS 的 knowledgeC 使用记录，只读不改。Apple 按「应用处于前台」逐段累加，
    本工具按「是否在场」判定，两者天然有差：看视频、开会、长时间读文档时手不动，本工具照算，
    Apple 则可能因为切到后台而少算。</div>"""


def compare_block(d, recent):
    """今日 vs 近 7 天日均：两根横条并排，比数字更好读"""
    def mean(xs):
        xs = [x for x in xs if x is not None]
        return sum(xs) / len(xs) if xs else None

    metrics = [
        ("用眼时长", d["screen"] / 3600, mean([r["screen"] / 3600 for r in recent]),
         lambda v: f"{v:.1f} 小时", "#1a73e8"),
        ("眼疲劳风险指数", d["score"], mean([r["score"] for r in recent]),
         lambda v: f"{v:.0f}", d["color"]),
        ("休息达成率", d["compliance"], mean([r["compliance"] for r in recent]),
         lambda v: f"{v:.0f}%", "#34a853"),
    ]

    out = []
    for name, today_v, avg_v, fmt, color in metrics:
        if today_v is None and avg_v is None:
            continue
        scale = max(today_v or 0, avg_v or 0) or 1
        w1 = (today_v or 0) / scale * 100
        w2 = (avg_v or 0) / scale * 100
        t_txt = fmt(today_v) if today_v is not None else "--"
        a_txt = fmt(avg_v) if avg_v is not None else "--"
        out.append(f"""
        <div class="cmp">
          <div class="t"><span>{name}</span>
            <span class="n">今日 <b>{t_txt}</b> · 近 7 天 {a_txt}</span></div>
          <div class="track"><i style="width:{w1:.0f}%;background:{color}"></i></div>
          <div class="track"><i style="width:{w2:.0f}%;background:#dadce0"></i></div>
          <div class="cap"><span><i style="background:{color}"></i>今日</span>
            <span><i style="background:#dadce0"></i>近 7 天日均</span></div>
        </div>""")
    return "".join(out)


def build_html(day, derived, trend_points, date_obj, source_note, recent, screentime=None):
    weekday = WEEKDAY_CN[date_obj.weekday()]
    d = derived
    total_span = max(d["active_span"], 1)

    segs = [
        ("屏幕用眼", d["screen"], "#1a73e8"),
        ("大休息", d["long_rest"], "#34a853"),
        ("微休息", d["micro_rest"], "#8ab4f8"),
        ("离开 / 未用眼", d["away"], "#dadce0"),
    ]
    segs = [s for s in segs if s[1] > 0] or [("暂无数据", 1, "#eef1f5")]

    legend_rows = "".join(
        f'<div class="row"><span class="sw" style="background:{c}"></span>'
        f'<span>{label}</span><span class="val"><b>{fmt_hm(sec)}</b> · {pct(sec, sum(s[1] for s in segs), 1)}%</span></div>'
        for label, sec, c in segs
    )

    kpis = f"""
    <div class="kpi">
      <div class="label">🖥️ 屏幕使用时间</div>
      <div class="value">{d['screen']/3600:.1f}<span class="unit">小时</span></div>
      <div class="foot">首次 {hhmm(day['first'])} · 末次 {hhmm(day['last'])}</div>
    </div>
    <div class="kpi">
      <div class="label">☕️ 休息总时长</div>
      <div class="value">{d['rest']/60:.0f}<span class="unit">分钟</span></div>
      <div class="foot">微休 {fmt_hm(d['micro_rest'])} · 大休 {fmt_hm(d['long_rest'])}</div>
    </div>
    <div class="kpi">
      <div class="label">⏱️ 平均连续用眼</div>
      <div class="value">{d['avg_session']/60:.0f}<span class="unit">分钟</span></div>
      <div class="foot">共 {d['sessions']} 段 · 最长 {fmt_hm(d['longest'])}</div>
    </div>
    <div class="kpi">
      <div class="label">✅ 休息达成率</div>
      <div class="value">{int(round(d['compliance'])) if d['compliance'] is not None else '--'}<span class="unit">%</span></div>
      <div class="foot">{d['breaks_done']} / {d['breaks_triggered']} 次完整休息</div>
    </div>
    """

    def compliance_chip(v):
        if v is None:
            return '<span class="chip">无记录</span>'
        v = int(round(v))
        if v >= 85:
            return f'<span class="chip green">{v}%</span>'
        if v >= 60:
            return f'<span class="chip blue">{v}%</span>'
        if v >= 35:
            return f'<span class="chip yellow">{v}%</span>'
        return f'<span class="chip red">{v}%</span>'

    micro_rate = pct(d["micro_c"], d["micro_t"]) if d["micro_t"] else None
    long_rate = pct(d["long_c"], d["long_t"]) if d["long_t"] else None

    def bar_block(title, done, total, rate, color):
        width = rate if rate is not None else 0
        return f"""
        <div class="bar-row">
          <div class="top"><span>{title}</span>
            <span class="n">{done} / {total} 次 {compliance_chip(rate)}</span></div>
          <div class="track"><i style="width:{width}%;background:{color}"></i></div>
        </div>"""

    parts_rows = ""
    for name, got, cap, note in d["parts"]:
        val = got / cap * 100
        color = "#34a853" if val < 40 else ("#f9ab00" if val < 70 else "#ea4335")
        parts_rows += f"""
        <div class="bar-row">
          <div class="top"><span>{name}</span><span class="n">{note} · 得分 {got:.0f}/{cap}</span></div>
          <div class="track"><i style="width:{val:.0f}%;background:{color}"></i></div>
        </div>"""

    hourly = day["hourly_screen"]

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>用眼播报 · {date_obj.strftime('%Y年%m月%d日')}</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">

  <div class="hero">
    <div>
      <h1>每日<b>用眼播报</b></h1>
      <div class="sub">{date_obj.strftime('%Y年%m月%d日')} · {weekday} · data from RestReminder</div>
      <div class="stripe"><i></i><i></i><i></i><i></i></div>
    </div>
    <div class="badge">
      <span style="width:8px;height:8px;border-radius:50%;background:{d['color']};display:inline-block"></span>
      用眼状态 · {d['grade']}
    </div>
  </div>

  <!-- ---------- 一、屏幕使用时间 ---------- -->
  <div class="sec-head">
    <span class="dot" style="background:#1a73e8"></span>
    <h2>一、屏幕使用时间</h2>
    <span class="hint">每小时用眼强度（悬停看明细）</span>
  </div>

  <div class="grid g-kpi" style="margin-bottom:20px">{kpis}</div>

  <div class="card">
    {bars24(hourly)}
    <div class="note">{source_note}</div>
  </div>

  <div class="card">
    {screentime_block(screentime, day)}
  </div>

  <!-- ---------- 二、休息时间 ---------- -->
  <div class="sec-head">
    <span class="dot" style="background:#34a853"></span>
    <h2>二、休息时间</h2>
    <span class="hint">一天里的时间是怎么分配掉的</span>
  </div>

  <div class="grid g2">
    <div class="card">
      <div style="display:flex;gap:26px;align-items:center;flex-wrap:wrap">
        <div style="flex:0 0 232px;max-width:232px">{donut(segs)}</div>
        <div class="legend" style="flex:1;min-width:220px">{legend_rows}</div>
      </div>
    </div>
    <div class="card">
      <div style="font-size:13px;color:var(--ink-2);margin-bottom:16px">双轨休息执行情况</div>
      {bar_block("🌱 微休息（每 15 分钟 / 15 秒）", d['micro_c'], d['micro_t'], micro_rate, "#8ab4f8")}
      {bar_block("☕️ 大休息（每 45 分钟）", d['long_c'], d['long_t'], long_rate, "#34a853")}
      <div class="rows" style="margin-top:8px">
        <div class="r"><span class="k">累计休息</span>
          <span style="color:var(--ink-3);font-size:12px">占活跃时段 {pct(d['rest'], total_span)}%</span>
          <span class="v">{fmt_hm(d['rest'])}</span></div>
        <div class="r"><span class="k">未用眼时长</span>
          <span style="color:var(--ink-3);font-size:12px">熄屏 / 锁屏 / 离开座位</span>
          <span class="v">{fmt_hm(d['away'])}</span></div>
      </div>
    </div>
  </div>

  <!-- ---------- 三、用眼状态 ---------- -->
  <div class="sec-head">
    <span class="dot" style="background:{d['color']}"></span>
    <h2>三、用眼状态</h2>
    <span class="hint">由时长、连续性、休息达成率、时段四项加权</span>
  </div>

  <div class="grid g2">
    <div class="card">
      <div style="display:flex;gap:24px;align-items:center;flex-wrap:wrap">
        <div style="flex:0 0 210px;max-width:210px">{gauge(d['score'], d['color'])}</div>
        <div style="flex:1;min-width:200px">
          <div style="font-size:26px;font-weight:500;color:{d['color']};letter-spacing:-.5px">{d['grade']}</div>
          <div class="verdict" style="margin-top:10px">
            <div class="ico" style="background:{d['color']}1a;color:{d['color']}">👁️</div>
            <p>{d['verdict']}</p>
          </div>
        </div>
      </div>
    </div>
    <div class="card">
      <div style="font-size:13px;color:var(--ink-2);margin-bottom:16px">风险构成（分数越高越该警惕）</div>
      {parts_rows}
    </div>
  </div>

  <div class="card">
    <div style="display:flex;align-items:baseline;justify-content:space-between;margin-bottom:8px">
      <div style="font-size:13px;color:var(--ink-2)">近 {len(trend_points)} 天用眼时长趋势</div>
      <div style="font-size:12px;color:var(--ink-3)">实心 = 新版实测 · 空心 = 旧日志估算</div>
    </div>
    {trend_chart(trend_points)}
  </div>

  <div class="card">
    <div style="font-size:13px;color:var(--ink-2);margin-bottom:20px">今日 vs 近 7 天日均</div>
    {compare_block(d, recent)}
  </div>

  <footer>
    RestReminder · 数据采集自本机，不上传任何服务器<br/>
    统计口径：屏幕用眼 = 判定为「人正在看屏幕」的秒数（含视频/会议）；休息 = 微休息与大休息的实际停留时长
  </footer>
</div>
</body>
</html>
"""


# ---------- 主流程 ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=None, help="YYYY-MM-DD，默认今天")
    ap.add_argument("--days", type=int, default=14, help="趋势窗口天数")
    ap.add_argument("--out", default=None, help="输出 html 路径")
    args = ap.parse_args()

    today = dt.date.today()
    target = dt.date.fromisoformat(args.date) if args.date else today

    log_days = parse_log()

    key = target.isoformat()
    refresh_screentime(key)
    real = read_stats(key)
    est = log_days.get(key)
    day = merge(real, est) or blank_day(key)

    # 趋势
    trend = []
    for i in range(args.days - 1, -1, -1):
        d0 = target - dt.timedelta(days=i)
        k = d0.isoformat()
        r = read_stats(k)
        e = log_days.get(k)
        m = merge(r, e)
        hours = (m["screen"] / 3600) if m and m["screen"] else 0.0
        trend.append((d0.strftime("%m/%d"), hours, bool(r and r["screen"] > 0)))

    derived = derive(day)

    # 近 7 天（不含今天），用于「今日 vs 日均」对比
    recent = []
    for i in range(1, 8):
        d0 = target - dt.timedelta(days=i)
        k = d0.isoformat()
        m = merge(read_stats(k), log_days.get(k))
        if m and m["screen"] > 0:
            recent.append(derive(m))

    # 数据来源说明
    src = day.get("source")
    if src == "real":
        note = ("数据来自新版实时记账（每秒累积），统计区间 "
                f"{hhmm(day['first'])} – {hhmm(day['last'])}。")
    elif src == "mixed":
        note = ("今日数据 = 新版实时记账 + 旧日志回溯补齐（同一小时取较大值）。"
                f"新版从 {hhmm((read_stats(key) or {}).get('first'))} 起开始精确记账，之前的时段由日志估算。")
    elif src == "log":
        note = "该日无实时记账文件，数据由 debug.log 的在场判定事件回溯估算，仅供参考。"
    else:
        note = "暂无该日数据 —— app 可能未运行或统计文件已被清理。"

    html = build_html(day, derived, trend, target, note, recent, read_screentime(key))

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = Path(args.out) if args.out else OUT_DIR / f"{key}.html"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(html, encoding="utf-8")

    print(f"已生成：{out}")
    print(f"  用眼 {fmt_hm(derived['screen'])} · 休息 {fmt_hm(derived['rest'])} · "
          f"状态 {derived['grade']}（{derived['score']}/100）")


if __name__ == "__main__":
    main()
