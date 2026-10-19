#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
读取 macOS 自带「屏幕使用时间」数据（knowledgeC.db）

Apple 把本机使用记录存在：
  ~/Library/Application Support/Knowledge/knowledgeC.db

这个库受 TCC 保护 —— 读它需要「完全磁盘访问权限」。没授权时会报
authorization denied / EPERM，脚本会明确提示怎么开。

只读，不改任何东西。

注意实现细节（踩过的坑）：
  * 不要用 `cp` / `shutil.copy2` 复制这个库。系统 copyfile(3) 路径会被
    TCC 直接拒掉（EPERM），而 Python 自己的 open() 是允许的。
    所以这里优先用 sqlite URI 的 mode=ro 直接开原库；只有在被写锁挡住时，
    才用 Python 逐块读出来落到临时目录再查。
  * ZSTARTDATE 是 Core Data 时间戳（2001-01-01 起算的秒）。库里存在少量
    异常值（0 或天文数字），换算时必须兜住，否则 datetime 直接抛
    OverflowError 把整轮导出带崩。

产出：~/Library/Application Support/RestReminder/screentime/YYYY-MM-DD.json

用法：
  python3 screentime.py --diagnose        # 看看有哪些数据流、能不能读
  python3 screentime.py --days 7          # 导出最近 7 天
  python3 screentime.py --date 2026-10-19 # 只导某一天
"""

import argparse
import datetime as dt
import json
import plistlib
import sqlite3
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
SRC_DB = HOME / "Library/Application Support/Knowledge/knowledgeC.db"
OUT_DIR = HOME / "Library/Application Support/RestReminder/screentime"
NAME_CACHE = HOME / "Library/Application Support/RestReminder/app-names.json"

# Core Data 的时间原点：2001-01-01 00:00:00 UTC
COCOA_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
# 合理区间：2001-01-01 ~ 2100-01-01，超出的一律当脏数据丢掉
T_MIN = 0.0
T_MAX = (dt.datetime(2100, 1, 1, tzinfo=dt.timezone.utc) - COCOA_EPOCH).total_seconds()

STREAM_APP_USAGE = "/app/usage"
STREAM_APP_WEB = "/app/webUsage"
STREAM_MEDIA = "/app/mediaUsage"
STREAM_BACKLIT = "/display/isBacklit"
STREAM_LOCKED = "/device/isLocked"

# 单条记录的时长上限：超过就认为是异常跨度（休眠未关记录等）
MAX_EVENT_SECONDS = 4 * 3600


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


FDA_HELP = """
读不到 {src}
─────────────────────────────────────────────
macOS 把「屏幕使用时间」原始数据放在受保护目录里，需要一次性授权：

  系统设置 → 隐私与安全性 → 完全磁盘访问权限
  → 点「+」，把 WorkBuddy 添加进去并打开开关
  → 完全退出 WorkBuddy 再重开（TCC 权限只在进程启动时读取）

授权后重新运行本脚本即可。
""".strip()


# ---------- 打开数据库 ----------

def _open_ro(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)


def _copy_via_python(src: Path, dst: Path):
    """用 Python 的 open() 逐块拷贝，绕开被 TCC 拒掉的 copyfile(3)。"""
    with open(src, "rb") as f, open(dst, "wb") as out:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)


def open_db():
    if not SRC_DB.exists():
        fail(f"找不到 {SRC_DB} —— 这台机器可能没开「屏幕使用时间」。")

    # 先探一下最基本的读取权（这一步失败就是真没授权）
    try:
        with open(SRC_DB, "rb") as f:
            f.read(16)
    except OSError:
        fail(FDA_HELP.format(src=SRC_DB))

    # 1) 直接只读打开原库：最快，且能读到 WAL 里的最新数据
    try:
        con = _open_ro(SRC_DB)
        con.execute("SELECT 1 FROM ZOBJECT LIMIT 1").fetchone()
        return con
    except sqlite3.DatabaseError as e:
        if "locked" not in str(e).lower() and "not a database" not in str(e).lower():
            raise
        first_err = e

    # 2) 被写锁挡住时，拷一份快照再查（含 -wal / -shm）
    tmp = Path(tempfile.gettempdir()) / "rr_knowledgeC_copy.db"
    for suffix in ("", "-wal", "-shm"):
        src = Path(str(SRC_DB) + suffix)
        if not src.exists():
            continue
        try:
            _copy_via_python(src, Path(str(tmp) + suffix))
        except OSError:
            if suffix == "":
                fail(FDA_HELP.format(src=SRC_DB))
    try:
        con = _open_ro(tmp)
        con.execute("SELECT 1 FROM ZOBJECT LIMIT 1").fetchone()
        return con
    except sqlite3.DatabaseError:
        fail(f"数据库既不能直读也不能快照（{first_err}）。\n"
             f"系统「屏幕使用时间」正在写库，稍后重试即可。")


def cocoa_to_dt(value):
    """Core Data 时间戳 → 带时区的本地时间。异常值返回 None。

    统一在这里转成本地时区：库里存的是 UTC 秒数，如果一路用 UTC 的
    .hour 去分桶，24 小时分布会整体偏移时区差（在北京会偏 8 小时）。
    """
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    if not (T_MIN < v < T_MAX):
        return None
    try:
        return (COCOA_EPOCH + dt.timedelta(seconds=v)).astimezone()
    except (OverflowError, OSError):
        return None


def to_cocoa(d):
    return (d - COCOA_EPOCH).total_seconds()


def columns(con, table):
    return [r[1] for r in con.execute(f"PRAGMA table_info({table})")]


def diagnose(con):
    print("数据流清单（ZSTREAMNAME）：")
    rows = con.execute(
        "SELECT ZSTREAMNAME, COUNT(*), MIN(ZSTARTDATE), MAX(ZSTARTDATE) "
        "FROM ZOBJECT GROUP BY ZSTREAMNAME ORDER BY 2 DESC"
    ).fetchall()
    for name, n, mn, mx in rows[:20]:
        a, b = cocoa_to_dt(mn), cocoa_to_dt(mx)
        fmt = lambda t: t.astimezone().strftime("%Y-%m-%d %H:%M") if t else "—"
        print(f"  {str(name)[:32]:34s} {n:>6d}  {fmt(a)} → {fmt(b)}")
    print("\nZOBJECT 字段：", ", ".join(columns(con, "ZOBJECT")))
    print(f"\n源库：{SRC_DB}")
    print("读取方式：Python 只读直连（无需复制）")


# ---------- 应用名 ----------

def load_app_names():
    """扫一遍应用目录，把 bundle id 映射成可读名字。扫一次后缓存。"""
    if NAME_CACHE.exists():
        try:
            cached = json.loads(NAME_CACHE.read_text(encoding="utf-8"))
            if cached.get("version") == 1:
                return cached["map"]
        except Exception:
            pass

    mapping = {}
    roots = [Path("/Applications"), Path("/System/Applications"),
             Path("/System/Applications/Utilities"), Path("/System/Library/CoreServices"),
             HOME / "Applications"]

    def scan(directory, depth=0):
        if depth > 4 or not directory.exists():
            return
        try:
            entries = list(directory.iterdir())
        except OSError:
            return
        for entry in entries:
            if entry.name.endswith(".app"):
                plist = entry / "Contents/Info.plist"
                if plist.exists():
                    try:
                        with open(plist, "rb") as f:
                            info = plistlib.load(f)
                        bid = info.get("CFBundleIdentifier")
                        name = (info.get("CFBundleDisplayName")
                                or info.get("CFBundleName")
                                or entry.stem)
                        if bid and bid not in mapping:
                            mapping[bid] = name
                    except Exception:
                        pass
            elif entry.is_dir() and not entry.name.startswith("."):
                scan(entry, depth + 1)

    for root in roots:
        scan(root)

    # 系统界面相关的兜底名字
    mapping.setdefault("com.apple.loginwindow", "登录窗口")
    mapping.setdefault("com.apple.dock", "程序坞")

    try:
        NAME_CACHE.parent.mkdir(parents=True, exist_ok=True)
        NAME_CACHE.write_text(
            json.dumps({"version": 1, "map": mapping}, ensure_ascii=False, indent=1),
            encoding="utf-8")
    except Exception:
        pass
    return mapping


# ---------- 聚合 ----------

def fetch_events(con, stream, start_dt, end_dt):
    has_end = "ZENDDATE" in columns(con, "ZOBJECT")
    sql = ("SELECT ZVALUESTRING, ZSTARTDATE, "
           + ("ZENDDATE" if has_end else "NULL")
           + " FROM ZOBJECT WHERE ZSTREAMNAME = ? AND ZSTARTDATE >= ? AND ZSTARTDATE < ?")
    return con.execute(sql, (stream, to_cocoa(start_dt), to_cocoa(end_dt))).fetchall()


def aggregate(con, day_start, day_end, names):
    """把一条时间线切成 24 桶，并汇总分应用时长。

    一条记录可能跨过午夜，按与 [day_start, day_end) 的实际重叠算，
    不整条塞进起始日。
    """
    buckets = {}
    hourly = [0.0] * 24
    switches = 0
    now = dt.datetime.now().astimezone()

    for bundle, start_raw, end_raw in fetch_events(con, STREAM_APP_USAGE, day_start, day_end):
        start = cocoa_to_dt(start_raw)
        if start is None:
            continue
        end = cocoa_to_dt(end_raw)
        if end is None or end <= start:
            # 没有结束时间的记录 = 当前仍在前台；只对今天补齐到此刻
            end = min(now, start + dt.timedelta(seconds=60)) if now > start else start
            if end <= start:
                continue
        seconds = min((end - start).total_seconds(), MAX_EVENT_SECONDS)
        if seconds <= 0:
            continue

        # 与当天的真实重叠
        lo = max(start, day_start)
        hi = min(end, day_end)
        if hi <= lo:
            continue
        overlap = (hi - lo).total_seconds()

        key = bundle or "unknown"
        buckets[key] = buckets.get(key, 0) + overlap
        switches += 1

        # 按小时切分（同一小时内的部分）
        cursor = lo
        while cursor < hi:
            hour_end = cursor.replace(minute=0, second=0, microsecond=0) + dt.timedelta(hours=1)
            seg_end = min(hour_end, hi)
            hourly[cursor.hour] += (seg_end - cursor).total_seconds()
            cursor = seg_end

    total = int(sum(buckets.values()))
    apps = sorted(
        ({"bundle": b, "name": names.get(b, b), "seconds": int(s)}
         for b, s in buckets.items()),
        key=lambda x: -x["seconds"],
    )

    # 解锁次数：/device/isLocked 只在 iOS 上有，macOS 不写这条流，
    # 所以这里通常拿不到数据，字段留着是为兼容旧文件/未来变化。
    unlocks, first_unlock = 0, None
    if _has_stream(con, STREAM_LOCKED):
        for value_str, value_int, start_raw in con.execute(
                "SELECT ZVALUESTRING, ZVALUEINTEGER, ZSTARTDATE FROM ZOBJECT "
                "WHERE ZSTREAMNAME = ? AND ZSTARTDATE >= ? AND ZSTARTDATE < ? "
                "ORDER BY ZSTARTDATE",
                (STREAM_LOCKED, to_cocoa(day_start), to_cocoa(day_end))).fetchall():
            is_locked = value_int if value_int is not None else (
                int(value_str) if value_str and value_str.isdigit() else None)
            if is_locked == 0:
                unlocks += 1
                ts = cocoa_to_dt(start_raw)
                if ts and first_unlock is None:
                    first_unlock = ts

    return {
        "date": day_start.strftime("%Y-%m-%d"),
        "totalSeconds": total,
        "apps": apps,
        "hourly": [int(round(x)) for x in hourly],
        # 应用切换次数：前台片段数，反映注意力的碎片化程度
        "switches": switches,
        "appCount": len(apps),
        "unlocks": unlocks,
        "firstUnlock": first_unlock.strftime("%H:%M") if first_unlock else None,
        "generatedAt": dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "source": "knowledgeC",
    }


_STREAM_CACHE = {}


def _has_stream(con, stream):
    if stream not in _STREAM_CACHE:
        row = con.execute("SELECT 1 FROM ZOBJECT WHERE ZSTREAMNAME = ? LIMIT 1",
                          (stream,)).fetchone()
        _STREAM_CACHE[stream] = row is not None
    return _STREAM_CACHE[stream]


def export_day(con, day, names):
    local_tz = dt.datetime.now().astimezone().tzinfo
    day_start = dt.datetime.combine(day, dt.time.min).replace(tzinfo=local_tz)
    day_end = day_start + dt.timedelta(days=1)
    data = aggregate(con, day_start, day_end, names)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{data['date']}.json"
    out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    return out, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--diagnose", action="store_true", help="打印数据流清单后退出")
    ap.add_argument("--date", default=None, help="YYYY-MM-DD")
    ap.add_argument("--days", type=int, default=1, help="导出最近 N 天")
    args = ap.parse_args()

    con = open_db()

    if args.diagnose:
        diagnose(con)
        return

    names = load_app_names()

    if args.date:
        days = [dt.date.fromisoformat(args.date)]
    else:
        today = dt.date.today()
        days = [today - dt.timedelta(days=i) for i in range(args.days - 1, -1, -1)]

    for day in days:
        out, data = export_day(con, day, names)
        h, m = divmod(data["totalSeconds"] // 60, 60)
        top = data["apps"][0]["name"] if data["apps"] else "—"
        print(f"{data['date']}  总计 {h}h{m:02d}m · 解锁 {data['unlocks']} 次 · "
              f"最常用 {top} → {out}")


if __name__ == "__main__":
    main()
