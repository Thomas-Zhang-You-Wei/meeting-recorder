import AppKit
import AVFoundation

// 兩種用法：
//   1. 直接開 .app → 選單列小程式
//   2. MeetingRecorder record ... → 命令列錄製（自動化測試用）
//      --mode online|physical  --screen  --seconds N  --name 名稱
//      --mic <裝置名稱關鍵字>  --bookmark-at 30,75  --no-process
//      錄製中送 SIGUSR1 可打書籤，SIGINT 提早停止
//   MeetingRecorder list-mics → 列出麥克風

let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func runCLI() -> Never {
    if args.first == "list-mics" {
        for d in AppDelegate.microphones() { print("\(d.localizedName)\t\(d.uniqueID)") }
        exit(0)
    }
    let mode = RecordingMode(rawValue: value("--mode") ?? "online") ?? .online
    let screen = mode == .online || args.contains("--screen")
    let seconds = Double(value("--seconds") ?? "60") ?? 60
    let name = value("--name") ?? "CLI測試"
    var micID: String?
    if let key = value("--mic") {
        guard let d = AppDelegate.microphones().first(where: { $0.localizedName.localizedCaseInsensitiveContains(key) }) else {
            FileHandle.standardError.write("找不到麥克風：\(key)\n".data(using: .utf8)!)
            exit(2)
        }
        micID = d.uniqueID
        print("麥克風：\(d.localizedName)")
    }
    let marks = (value("--bookmark-at") ?? "").split(separator: ",").compactMap { Double($0) }

    let dir: URL
    do { dir = try Paths.makeSessionDir(name: name) } catch { print("無法建立資料夾：\(error)"); exit(1) }
    let rec = Recorder(dir: dir, name: name, options: RecordingOptions(mode: mode, captureScreen: screen, micDeviceID: micID))

    signal(SIGUSR1, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    var stopEarly = false
    usr1.setEventHandler { let b = rec.addBookmark(); print("書籤 \(b.label) @ \(fmt(b.t))") }
    sigint.setEventHandler { stopEarly = true }
    usr1.resume()
    sigint.resume()

    Task { @MainActor in
        do {
            try await rec.start()
        } catch {
            print("無法開始錄製：\(error.localizedDescription)")
            exit(1)
        }
        print("錄製中 → \(dir.path)（\(mode.label)，螢幕：\(screen)）")
        var pendingMarks = marks.sorted()
        while rec.elapsed < seconds && !stopEarly {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if let m = pendingMarks.first, rec.elapsed >= m {
                pendingMarks.removeFirst()
                let b = rec.addBookmark()
                print("書籤 \(b.label) @ \(fmt(b.t))")
            }
        }
        let d = await rec.stop()
        print(String(format: "已停止，長度 %.1f 秒", d))
        if args.contains("--no-process") {
            // 留一個 process.log，選單 App 下次啟動時才不會把它當成「還沒轉錄」自動補做
            try? "已用 --no-process 略過後處理；要轉錄請手動執行 mr_process.py\n"
                .write(to: dir.appendingPathComponent("process.log"), atomically: true, encoding: .utf8)
            exit(0)
        }
        print("後處理中（log：\(dir.path)/process.log）")
        PostProcess.launch(sessionDir: dir) { code in
            print("後處理結束碼 \(code)")
            exit(code)
        }
    }
    dispatchMain()
}

if args.first == "record" || args.first == "list-mics" {
    runCLI()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
