import Foundation

/// 所有路徑集中在這裡。資料（venv、術語表）放 Application Support，
/// 產出放 ~/Movies/MeetingRecorder，兩者都不在 repo 裡。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var support: URL {
        home.appendingPathComponent("Library/Application Support/MeetingRecorder", isDirectory: true)
    }

    static var outputRoot: URL {
        if let custom = ProcessInfo.processInfo.environment["MEETING_RECORDER_OUTPUT"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return home.appendingPathComponent("Movies/MeetingRecorder", isDirectory: true)
    }

    static var glossary: URL { support.appendingPathComponent("glossary.txt") }

    /// 錄製中的鎖定檔（第一行是 pid）。build.sh 看到它就不會砍掉正在錄的 App。
    static var recordingLock: URL { support.appendingPathComponent("recording.lock") }

    static func writeRecordingLock(dir: URL) {
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let text = "\(ProcessInfo.processInfo.processIdentifier)\n\(dir.path)\n"
        try? text.write(to: recordingLock, atomically: true, encoding: .utf8)
    }

    /// 只刪自己寫的鎖（命令列與選單 App 同時錄時，先停的不能把對方的鎖刪掉）。
    static func removeRecordingLock() {
        let me = "\(ProcessInfo.processInfo.processIdentifier)"
        guard let text = try? String(contentsOf: recordingLock, encoding: .utf8),
              text.split(separator: "\n").first.map(String.init) == me else { return }
        try? FileManager.default.removeItem(at: recordingLock)
    }

    static var python: URL { support.appendingPathComponent("venv/bin/python") }

    /// build.sh 把腳本、播放器範本、預設術語表裝在這裡。
    /// 刻意不放進 .app：App 內容一變，ad-hoc 簽章就變，螢幕錄製授權會失效。
    static var scriptsDir: URL { support.appendingPathComponent("scripts", isDirectory: true) }

    /// 後處理腳本：優先用 Application Support 裡的，找不到時退回執行檔附近的 scripts/（開發時用）。
    static var processScript: URL {
        let installed = scriptsDir.appendingPathComponent("mr_process.py")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            let u = dir.appendingPathComponent("scripts/mr_process.py")
            if FileManager.default.fileExists(atPath: u.path) { return u }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: "scripts/mr_process.py")
    }

    /// 建立 YYYY-MM-DD_HHMM_<名稱>/，重名時加 _2、_3。
    static func makeSessionDir(name: String, date: Date = Date()) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        var safe = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for ch in ["/", ":", "\\", "\n", "\r", "\t"] { safe = safe.replacingOccurrences(of: ch, with: "-") }
        if safe.isEmpty { safe = "會議" }
        let base = "\(f.string(from: date))_\(safe)"
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        var url = outputRoot.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = outputRoot.appendingPathComponent("\(base)_\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
