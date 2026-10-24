import Foundation

/// 啟動 mr_process.py（ffmpeg 合成 → mlx-whisper 轉錄 → 產出 srt/md/html → 通知）。
enum PostProcess {
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // 從選單列啟動時 PATH 只有系統路徑，補上 Homebrew 才找得到 ffmpeg
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "")
        env["HF_HUB_OFFLINE"] = "1"         // 轉錄全程不連網
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// 在背景執行，完成時在主執行緒呼叫 completion(結束碼)。
    @discardableResult
    static func launch(sessionDir: URL, completion: ((Int32) -> Void)? = nil) -> Process? {
        let p = Process()
        p.executableURL = Paths.python
        p.arguments = [Paths.processScript.path, sessionDir.path]
        p.environment = environment()
        let logURL = sessionDir.appendingPathComponent("process.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async { completion?(proc.terminationStatus) }
        }
        do {
            try p.run()
            return p
        } catch {
            NSLog("無法啟動後處理：\(error)（python: \(Paths.python.path)）")
            DispatchQueue.main.async { completion?(-1) }
            return nil
        }
    }
}
