import Foundation

// MARK: - 每日用眼统计
//
// 埋点原则：只在「真实发生」的位置记一笔，不做事后推测。
// 落盘：~/Library/Application Support/RestReminder/stats/yyyy-MM-dd.json
//
//   · 每天一个文件，跨天自动切换（tick 里检测日期变化）
//   · 启动时回读当天文件 —— app 重启不会把今天的账清零
//   · 写入节流 15 秒，避免每秒刷盘；跨天与退出前强制 flush
//
// 所有调用都在主线程（tick 与各休息回调），所以不加锁。

final class Stats {

    static let shared = Stats()

    // MARK: - 单日数据结构
    //
    // 字段刻意保持「原始累积量」的形态：只存秒数和计数，
    // 达成率、平均值这类派生指标全部交给播报脚本算，方便以后改口径。

    private struct DayStats: Codable {
        var date: String
        var screenSeconds: Int        // 屏幕用眼（focusing + watching）
        var awaySeconds: Int          // 离开：熄屏 / 锁屏 / 无输入 / 已休息
        var pausedSeconds: Int        // 手动暂停

        var microTriggered: Int       // 微休息弹出次数
        var microCompleted: Int       // 自然完成次数
        var microRestSeconds: Int     // 微休息累计秒数

        var longTriggered: Int        // 大休息到点次数
        var longCompleted: Int        // 实际进入并结束休息的次数
        var longRestSeconds: Int      // 大休息累计秒数

        var hourlyScreen: [Int]       // 24 个小时桶的用眼秒数
        var hourlyBreaks: [Int]       // 24 个小时桶的休息次数

        var firstScreenAt: String?    // 当天首次用眼时间 HH:mm
        var lastScreenAt: String?     // 当天最近一次用眼时间 HH:mm
        var longestSessionSeconds: Int  // 最长连续用眼
        var sessionCount: Int         // 开始了几段连续用眼

        var updatedAt: String
        var version: Int

        static func empty(date: String) -> DayStats {
            DayStats(
                date: date,
                screenSeconds: 0, awaySeconds: 0, pausedSeconds: 0,
                microTriggered: 0, microCompleted: 0, microRestSeconds: 0,
                longTriggered: 0, longCompleted: 0, longRestSeconds: 0,
                hourlyScreen: Array(repeating: 0, count: 24),
                hourlyBreaks: Array(repeating: 0, count: 24),
                firstScreenAt: nil, lastScreenAt: nil,
                longestSessionSeconds: 0, sessionCount: 0,
                updatedAt: "", version: 1
            )
        }
    }

    // MARK: - 状态

    private var day: DayStats
    private var currentSessionSeconds = 0
    private var microBreakStart: Date?
    private var longBreakStart: Date?
    private var lastWrite = Date.distantPast
    private let writeInterval: TimeInterval = 15

    private let dirURL: URL
    private let dayFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let stampFormatter: DateFormatter
    private let jsonEncoder: JSONEncoder

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dirURL = base.appendingPathComponent("RestReminder/stats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let today = dayFormatter.string(from: Date())
        day = DayStats.empty(date: today)

        // 回读当天已有的账本（app 可能今天已经重启过几次）
        if let data = try? Data(contentsOf: fileURL(for: today)),
           let saved = try? JSONDecoder().decode(DayStats.self, from: data) {
            day = saved
            if day.hourlyScreen.count != 24 { day.hourlyScreen = Array(repeating: 0, count: 24) }
            if day.hourlyBreaks.count != 24 { day.hourlyBreaks = Array(repeating: 0, count: 24) }
        }
    }

    // MARK: - 路径

    private func fileURL(for date: String) -> URL {
        dirURL.appendingPathComponent("\(date).json")
    }

    /// 跨天处理：把前一天的账结掉，开一本新的
    private func rolloverIfNeeded() {
        let today = dayFormatter.string(from: Date())
        guard today != day.date else { return }

        flush(force: true)

        currentSessionSeconds = 0
        microBreakStart = nil
        longBreakStart = nil
        day = DayStats.empty(date: today)
    }

    // MARK: - 用眼 / 离开

    /// 有 1 秒被判定为「正在看屏幕」（专注或媒体播放中）
    func recordFocus() {
        rolloverIfNeeded()

        let now = Date()
        day.screenSeconds += 1
        day.hourlyScreen[hourIndex(now)] += 1

        currentSessionSeconds += 1
        if currentSessionSeconds == 1 { day.sessionCount += 1 }
        if currentSessionSeconds > day.longestSessionSeconds {
            day.longestSessionSeconds = currentSessionSeconds
        }

        if day.firstScreenAt == nil { day.firstScreenAt = timeFormatter.string(from: now) }
        day.lastScreenAt = timeFormatter.string(from: now)

        scheduleWriteIfNeeded()
    }

    /// 有 1 秒被判定为离开屏幕
    func recordAway() {
        rolloverIfNeeded()
        day.awaySeconds += 1
        endSession()
        scheduleWriteIfNeeded()
    }

    /// 有 1 秒被手动暂停
    func recordPaused() {
        rolloverIfNeeded()
        day.pausedSeconds += 1
        endSession()
        scheduleWriteIfNeeded()
    }

    private func endSession() {
        currentSessionSeconds = 0
    }

    // MARK: - 微休息

    func microBreakStarted() {
        rolloverIfNeeded()
        day.microTriggered += 1
        day.hourlyBreaks[hourIndex(Date())] += 1
        microBreakStart = Date()
        endSession()
        flush(force: true)
    }

    func microBreakEnded(naturally: Bool) {
        rolloverIfNeeded()
        if naturally { day.microCompleted += 1 }
        let spent: Int
        if let start = microBreakStart {
            spent = max(0, Int(Date().timeIntervalSince(start).rounded()))
        } else {
            spent = 0
        }
        day.microRestSeconds += spent
        microBreakStart = nil
        day.lastScreenAt = timeFormatter.string(from: Date())
        flush(force: true)
    }

    // MARK: - 大休息

    func longBreakTriggered() {
        rolloverIfNeeded()
        day.longTriggered += 1
        endSession()
        scheduleWriteIfNeeded()
    }

    /// 真正开始躺着休息的瞬间（进了循环画面，或真的熄屏了）
    func longBreakStarted() {
        rolloverIfNeeded()
        longBreakStart = Date()
        endSession()
        flush(force: true)
    }

    /// 休息结束。preview 为 true 的预览不计入统计；
    /// 没有开过休息（longBreakStart 为空）时也不记 —— 避免把普通的「屏幕亮回来」算成休息。
    func longBreakEnded(preview: Bool) {
        guard !preview, longBreakStart != nil else { return }
        rolloverIfNeeded()

        let seconds = max(0, Int(Date().timeIntervalSince(longBreakStart!).rounded()))
        day.longCompleted += 1
        day.longRestSeconds += seconds
        longBreakStart = nil
        day.lastScreenAt = timeFormatter.string(from: Date())
        flush(force: true)
    }

    // MARK: - 写盘

    private func hourIndex(_ date: Date) -> Int {
        let h = Calendar.current.component(.hour, from: date)
        return min(max(h, 0), 23)
    }

    private func scheduleWriteIfNeeded() {
        if Date().timeIntervalSince(lastWrite) >= writeInterval {
            flush(force: false)
        }
    }

    func flush(force: Bool) {
        guard force || Date().timeIntervalSince(lastWrite) >= writeInterval else { return }
        lastWrite = Date()
        day.updatedAt = stampFormatter.string(from: lastWrite)

        guard let data = try? jsonEncoder.encode(day) else { return }
        try? data.write(to: fileURL(for: day.date), options: .atomic)
    }
}
