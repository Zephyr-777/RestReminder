import Foundation

// MARK: - 目录约定
//
// 程序自己产生的所有数据都落在 macOS 的标准位置，源码目录里一个字都不写。
//
// 这样做有两个好处：
//   1. 符合 macOS 习惯 —— ~/Library 归用户数据，app 包里只放代码；
//   2. 仓库可以直接开源，clone 下来不用改任何路径。
//
// 目录结构：
//   ~/Library/Application Support/RestReminder/
//     stats/YYYY-MM-DD.json          每秒记账的原始数据
//     screentime/YYYY-MM-DD.json     从 knowledgeC.db 读出的 Apple 屏幕使用时间
//     reports/YYYY-MM-DD.html        生成的播报
//     tools/{daily_report,screentime}.py   由 install.sh 安装
//   ~/Library/Logs/RestReminder/debug.log
enum Paths {

    /// `~/Library/Application Support/RestReminder`
    static let support: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
        let url = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support"))
            .appendingPathComponent("RestReminder", isDirectory: true)
        return url.path
    }()

    /// `~/Library/Logs/RestReminder`
    static let logs: String = {
        let base = FileManager.default.urls(for: .libraryDirectory,
                                           in: .userDomainMask).first
        let url = (base ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library"))
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RestReminder", isDirectory: true)
        return url.path
    }()

    static var statsDir: String { support + "/stats" }
    static var screentimeDir: String { support + "/screentime" }
    static var reportsDir: String { support + "/reports" }
    /// 播报脚本的安装位置（由 install.sh 从 tools/ 拷过来）
    static var toolsDir: String { support + "/tools" }
    static var logFile: String { logs + "/debug.log" }

    /// 需要时创建目录。失败不致命，调用方自己决定要不要记日志。
    @discardableResult
    static func ensure(_ dir: String) -> Bool {
        (try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)) != nil
    }
}
