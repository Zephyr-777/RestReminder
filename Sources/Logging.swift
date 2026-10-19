import Foundation

// MARK: - 调试日志
//
// 相比原来的两点改动：
//   1. **轮转**：原先是无限增长（已经到 143KB 且只增不减）。
//      现在打开文件时若超过 `logMaxBytes`，就截断到最近 `logKeepLines` 行。
//   2. **写入开销**：原先每次都 open + seek + write + close（每条日志 3~4 次系统调用）。
//      现在用常驻 FileHandle，每条日志只有一次 write。
//
// 注意：logFileHandle 是全局可变状态。这个 app 里 logDebug 只在主线程被调用，
// 所以不需要加锁。如果以后要在后台线程写日志，得加串行队列。

private let logPath = Paths.logFile
private let logMaxBytes = 512 * 1024
private let logKeepLines = 2000

private func rotateLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
          let size = attrs[.size] as? Int,
          size > logMaxBytes else { return }
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let keep = lines.suffix(logKeepLines).joined(separator: "\n")
    let header = "// --- 日志已轮转（原文件 \(size / 1024) KB，保留最近 \(logKeepLines) 行）---\n"
    try? (header + keep + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
}

private let logFileHandle: FileHandle? = {
    Paths.ensure(Paths.logs)
    rotateLogIfNeeded()
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    let h = FileHandle(forWritingAtPath: logPath)
    h?.seekToEndOfFile()
    return h
}()

func logDebug(_ str: String) {
    let line = "\(Date()): \(str)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = logFileHandle {
        h.write(data)
    } else {
        // 句柄打不开时的兜底：至少还能把第一条写进去
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}
