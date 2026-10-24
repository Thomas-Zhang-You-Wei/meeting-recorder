import AppKit
import AVFoundation
import Carbon

/// 選單列小程式本體。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var starting = false                   // start() 還在等 SCStream 開起來
    private var errorWhileStarting: Error?         // 啟動那一瞬間就出錯：等 start() 回來再處理
    private var timer: Timer?
    private var bookmarkKey: HotKey?
    private var processing: [String] = []          // 轉錄中的會議資料夾名稱
    private var pending: [URL] = []                // 排隊等轉錄
    private let micDefaultsKey = "micDeviceID"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 新圖示預設排在最靠近瀏海的位置，選單列一擠就被擋住。第一次啟動時改放在
        // 離右邊緣 420 pt 的地方；使用者用 ⌘ 拖過之後，macOS 會記住新位置，這個預設就不再作用。
        UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Item-0": 420.0])
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        // ⌃⌥B 打書籤
        bookmarkKey = HotKey(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey), id: 1) { [weak self] in
            self?.addBookmark()
        }
        // 第一次啟動先觸發麥克風授權詢問，避免開會當下才跳視窗
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // 上次結束 App 時還沒轉錄完的會議，補排進佇列
        for dir in Self.unprocessedSessions() { enqueue(dir) }
    }

    /// 有原始錄製檔、但還沒跑過後處理（沒有 process.log）的會議資料夾。
    static func unprocessedSessions() -> [URL] {
        let fm = FileManager.default
        var busy: String?
        if let lock = try? String(contentsOf: Paths.recordingLock, encoding: .utf8) {
            let lines = lock.split(separator: "\n").map(String.init)
            if let pid = Int32(lines.first ?? ""), kill(pid, 0) == 0, lines.count > 1 { busy = lines[1] }
        }
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.outputRoot, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { d in
            let has = { fm.fileExists(atPath: d.appendingPathComponent($0).path) }
            return d.path != busy && !has("process.log") && !has("recording.mp4")
                && (has("mic.caf") || has("system.caf") || has("video.mov"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: 選單

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let r = recorder, starting {
            menu.addItem(disabled("啟動錄製中…　\(r.name)"))
        } else if let r = recorder {
            menu.addItem(disabled("● 錄製中（\(r.options.mode.label)）\(fmt(r.elapsed))　\(r.name)"))
            menu.addItem(item("停止錄製並轉錄", #selector(stopRecordingMenu), key: "s"))
            menu.addItem(item("加書籤（⌃⌥B）", #selector(addBookmarkMenu)))
            if !r.bookmarks.isEmpty { menu.addItem(disabled("　已有 \(r.bookmarks.count) 個書籤")) }
        } else {
            menu.addItem(item("開始線上會議錄製（螢幕＋系統音＋麥克風）", #selector(startOnline)))
            menu.addItem(item("開始實體會議錄製（只錄麥克風）", #selector(startPhysical)))
            menu.addItem(item("開始實體會議錄製（麥克風＋螢幕）", #selector(startPhysicalScreen)))
        }
        if !processing.isEmpty || !pending.isEmpty {
            menu.addItem(.separator())
            for n in processing { menu.addItem(disabled("轉錄中：\(n)")) }
            for u in pending { menu.addItem(disabled("排隊中：\(u.lastPathComponent)")) }
        }
        menu.addItem(.separator())
        let micItem = NSMenuItem(title: "麥克風", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu()
        micItem.isEnabled = recorder == nil
        menu.addItem(micItem)
        menu.addItem(item("開啟錄影資料夾", #selector(openOutput)))
        menu.addItem(item("編輯術語表", #selector(openGlossary)))
        menu.addItem(.separator())
        menu.addItem(item("結束 Meeting Recorder", #selector(quit), key: "q"))
    }

    private func micMenu() -> NSMenu {
        let m = NSMenu()
        let current = UserDefaults.standard.string(forKey: micDefaultsKey)
        let def = item("系統預設", #selector(selectMic(_:)))
        def.representedObject = nil
        def.state = current == nil ? .on : .off
        m.addItem(def)
        for d in Self.microphones() {
            let i = item(d.localizedName, #selector(selectMic(_:)))
            i.representedObject = d.uniqueID
            i.state = current == d.uniqueID ? .on : .off
            m.addItem(i)
        }
        return m
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    // MARK: 動作

    @objc private func startOnline() { start(mode: .online, screen: true) }
    @objc private func startPhysical() { start(mode: .physical, screen: false) }
    @objc private func startPhysicalScreen() { start(mode: .physical, screen: true) }

    private func start(mode: RecordingMode, screen: Bool) {
        guard recorder == nil, let name = askName() else { return }
        let opts = RecordingOptions(mode: mode, captureScreen: screen,
                                    micDeviceID: UserDefaults.standard.string(forKey: micDefaultsKey))
        let dir: URL
        do { dir = try Paths.makeSessionDir(name: name) } catch { alert("無法建立資料夾", error); return }
        let r = Recorder(dir: dir, name: name, options: opts)
        r.onError = { [weak self] err in
            DispatchQueue.main.async {
                guard let self, self.recorder === r else { return }
                if self.starting { self.errorWhileStarting = err; return }
                // 先收尾存檔，再跳對話框；對話框開著的時間不能算進錄影
                self.stopRecording {
                    self.alert("錄製中斷，已儲存到目前為止的內容並開始轉錄", err)
                }
            }
        }
        recorder = r
        starting = true
        updateIcon()
        Task { @MainActor in
            do {
                try await r.start()
                self.starting = false
                if let err = self.errorWhileStarting {
                    self.errorWhileStarting = nil
                    self.stopRecording { self.alert("錄製中斷，已儲存到目前為止的內容並開始轉錄", err) }
                    return
                }
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateIcon() }
            } catch {
                self.starting = false
                self.errorWhileStarting = nil
                if self.recorder === r { self.recorder = nil }
                self.updateIcon()
                try? FileManager.default.removeItem(at: dir)
                self.alert("無法開始錄製", error)
            }
        }
    }

    @objc private func stopRecordingMenu() { stopRecording() }

    private func stopRecording(then done: (() -> Void)? = nil) {
        guard let r = recorder, !starting else { return }
        recorder = nil
        timer?.invalidate()
        timer = nil
        updateIcon()
        Task { @MainActor in
            _ = await r.stop()
            self.enqueue(r.dir)
            done?()
        }
    }

    @objc private func addBookmarkMenu() { addBookmark() }

    private func addBookmark() {
        guard let r = recorder else { NSSound.beep(); return }
        let b = r.addBookmark()
        NSSound(named: "Tink")?.play()
        NSLog("書籤 \(b.label) @ \(fmt(b.t))")
    }

    private func enqueue(_ dir: URL) {
        pending.append(dir)
        runNext()
    }

    private func runNext() {
        guard processing.isEmpty, !pending.isEmpty else { updateIcon(); return }
        let dir = pending.removeFirst()
        processing.append(dir.lastPathComponent)
        updateIcon()
        let launched = PostProcess.launch(sessionDir: dir) { [weak self] code in
            guard let self else { return }
            self.processing.removeAll { $0 == dir.lastPathComponent }
            if code != 0 {
                self.alert("轉錄失敗（結束碼 \(code)）", "詳見 \(dir.path)/process.log")
            }
            self.runNext()
        }
        if launched == nil { processing.removeAll { $0 == dir.lastPathComponent } }
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            UserDefaults.standard.set(id, forKey: micDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: micDefaultsKey)
        }
    }

    @objc private func openOutput() {
        try? FileManager.default.createDirectory(at: Paths.outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.outputRoot)
    }

    @objc private func openGlossary() {
        if !FileManager.default.fileExists(atPath: Paths.glossary.path) {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            let def = Paths.scriptsDir.appendingPathComponent("glossary.default.txt")
            try? FileManager.default.copyItem(at: def, to: Paths.glossary)
        }
        NSWorkspace.shared.open(Paths.glossary)
    }

    @objc private func quit() {
        if starting { NSSound.beep(); return }
        if recorder != nil {
            let a = NSAlert()
            a.messageText = "正在錄製，要停止並結束嗎？"
            a.informativeText = "會先儲存錄影；轉錄會在背景繼續跑完。"
            a.addButton(withTitle: "停止並結束")
            a.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn, let r = recorder else { return }
            recorder = nil
            Task { @MainActor in
                _ = await r.stop()
                PostProcess.launch(sessionDir: r.dir)
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: UI 小工具

    private func askName() -> String? {
        let a = NSAlert()
        a.messageText = "會議名稱"
        a.informativeText = "會用在資料夾名稱，例如「週會」。"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = UserDefaults.standard.string(forKey: "lastName") ?? "週會"
        a.accessoryView = tf
        a.addButton(withTitle: "開始錄製")
        a.addButton(withTitle: "取消")
        a.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(name, forKey: "lastName")
        return name
    }

    private func alert(_ title: String, _ detail: Any) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = (detail as? Error)?.localizedDescription ?? "\(detail)"
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if let r = recorder {
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "錄製中")
            button.contentTintColor = .systemRed
            button.title = " " + fmt(r.elapsed)
        } else if !processing.isEmpty {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "轉錄中")
            button.contentTintColor = nil
            button.title = ""
        } else {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "Meeting Recorder")
            button.contentTintColor = nil
            button.title = ""
        }
    }
}

func fmt(_ t: Double) -> String {
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}
