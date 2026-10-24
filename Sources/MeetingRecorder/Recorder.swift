import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum RecordingMode: String {
    case online     // 螢幕 + 系統音 + 麥克風
    case physical   // 麥克風（可選加螢幕）

    var label: String { self == .online ? "線上" : "實體" }
}

struct RecordingOptions {
    var mode: RecordingMode
    var captureScreen: Bool
    var micDeviceID: String?   // nil = 系統預設麥克風

    var captureSystemAudio: Bool { mode == .online }
}

struct Bookmark: Codable {
    var t: Double
    var label: String
}

enum RecorderError: LocalizedError {
    case noDisplay
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "找不到可錄製的螢幕（請確認已授權「螢幕與系統錄音」）"
        case .writerFailed(let s): return "影片寫入失敗：\(s)"
        }
    }
}

/// 用 ScreenCaptureKit 的單一 SCStream 同時擷取螢幕、系統音、麥克風（macOS 15+）。
/// 三路各自寫成檔案（video.mov / system.caf / mic.caf），時間軸都從 t0 起算，
/// 停止後由 mr_process.py 用 ffmpeg 合成 recording.mp4。
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let dir: URL
    let options: RecordingOptions
    let name: String
    private(set) var startedAt = Date()
    private(set) var bookmarks: [Bookmark] = []

    private var stream: SCStream?
    private var t0 = CMTime.invalid
    private let videoQueue = DispatchQueue(label: "mr.video")
    private let audioQueue = DispatchQueue(label: "mr.audio")
    private let micQueue = DispatchQueue(label: "mr.mic")

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastVideoPTS = CMTime.invalid
    private var firstVideoOffset: Double?
    private var videoFrames = 0
    private var systemSink: AudioSink?
    private var micSink: AudioSink?

    var onError: ((Error) -> Void)?

    init(dir: URL, name: String, options: RecordingOptions) {
        self.dir = dir
        self.name = name
        self.options = options
    }

    var elapsed: Double {
        guard t0.isValid else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), t0))
    }

    @discardableResult
    func addBookmark(label: String? = nil) -> Bookmark {
        let b = Bookmark(t: max(0, elapsed), label: label ?? "書籤 \(bookmarks.count + 1)")
        bookmarks.append(b)
        return b
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        // 不錄自己的視窗（輸入會議名稱的對話框等）
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        var width = 16, height = 16
        if options.captureScreen {
            // 依實際像素，但最寬 1920，夠看清投影片又不會太大
            let scale = CGFloat(filter.pointPixelScale)
            var w = filter.contentRect.width * scale
            var h = filter.contentRect.height * scale
            if w > 1920 { h = h * 1920 / w; w = 1920 }
            width = Int(w) / 2 * 2
            height = Int(h) / 2 * 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            cfg.showsCursor = true
        } else {
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false
        }
        cfg.width = width
        cfg.height = height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 6

        cfg.capturesAudio = options.captureSystemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        cfg.captureMicrophone = true
        if let id = options.micDeviceID { cfg.microphoneCaptureDeviceID = id }

        if options.captureScreen { try setupVideoWriter(width: width, height: height) }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        // 沒錄螢幕時仍要掛 screen output，否則 SCStream 會一直警告丟幀
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.captureSystemAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)

        t0 = CMClockGetTime(CMClockGetHostTimeClock())
        startedAt = Date()
        if options.captureSystemAudio {
            systemSink = AudioSink(url: dir.appendingPathComponent("system.caf"), t0: t0)
        }
        micSink = AudioSink(url: dir.appendingPathComponent("mic.caf"), t0: t0)
        if let writer {
            writer.startWriting()
            writer.startSession(atSourceTime: t0)
        }

        stream = s
        try await s.startCapture()
        Paths.writeRecordingLock(dir: dir)
    }

    private func setupVideoWriter(width: Int, height: Int) throws {
        let url = dir.appendingPathComponent("video.mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        // 每 10 秒寫一次 fragment：App 當掉或被砍時，已錄的部分仍然打得開
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard w.canAdd(input) else { throw RecorderError.writerFailed("無法加入影像軌") }
        w.add(input)
        writer = w
        videoInput = input
        adaptor = ad
    }

    /// 停止擷取並把三路檔案寫完，回傳實際錄製秒數。
    func stop() async -> Double {
        let duration = elapsed
        if let stream {
            do { try await stream.stopCapture() } catch { NSLog("stopCapture: \(error)") }
        }
        stream = nil
        // 等各 queue 上已排隊的 buffer 處理完
        videoQueue.sync {}
        audioQueue.sync {}
        micQueue.sync {}

        if let writer, let videoInput, let adaptor {
            let end = CMTimeAdd(t0, CMTime(seconds: duration, preferredTimescale: 600))
            // 畫面靜止時 SCStream 不送新幀；在結尾補一幀，讓影片長度等於錄製長度
            if let pb = lastPixelBuffer, CMTimeCompare(end, lastVideoPTS) > 0, videoInput.isReadyForMoreMediaData {
                adaptor.append(pb, withPresentationTime: end)
            }
            videoInput.markAsFinished()
            writer.endSession(atSourceTime: end)
            await writer.finishWriting()
            if writer.status == .failed { NSLog("video writer failed: \(String(describing: writer.error))") }
        }
        lastPixelBuffer = nil
        systemSink?.finish(duration: duration)
        micSink?.finish(duration: duration)
        writeSessionJSON(duration: duration)
        Paths.removeRecordingLock()
        return duration
    }

    private func writeSessionJSON(duration: Double) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        var tracks: [String: Any] = [
            "video": videoFrames > 0,
            "system": systemSink?.hasData ?? false,
            "mic": micSink?.hasData ?? false,
        ]
        tracks["first_offsets"] = [
            "video": firstVideoOffset as Any,
            "system": systemSink?.firstOffset as Any,
            "mic": micSink?.firstOffset as Any,
        ]
        let obj: [String: Any] = [
            "name": name,
            "mode": options.mode.rawValue,
            "capture_screen": options.captureScreen,
            "started_at": iso.string(from: startedAt),
            "duration": duration,
            "bookmarks": bookmarks.map { ["t": $0.t, "label": $0.label] },
            "tracks": tracks,
            "video_frames": videoFrames,
            "warnings": (systemSink?.warnings ?? []).map { "系統音：\($0)" } + (micSink?.warnings ?? []).map { "麥克風：\($0)" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("session.json"))
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sb)
        case .audio:
            systemSink?.append(sb)
        case .microphone:
            micSink?.append(sb)
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard options.captureScreen, let videoInput, let adaptor, let writer, writer.status == .writing else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = sb.imageBuffer else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard CMTimeCompare(pts, t0) >= 0 else { return }
        if lastVideoPTS.isValid, CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
        guard videoInput.isReadyForMoreMediaData else { return }
        // 第一幀通常比 t0 晚零點幾秒到。把它也補寫在 t0，影片才會從 0 秒開始，
        // 否則 mov 開頭是一段空的 edit，ffmpeg 合成時會把它吃掉，整支影片就比聲音早。
        if !lastVideoPTS.isValid, CMTimeCompare(pts, t0) > 0 {
            guard adaptor.append(pb, withPresentationTime: t0) else { return }
            // 寫成功就要記下來，否則 writer 暫時忙碌時下一幀會再寫一次 t0，時間戳重複會讓整支影片作廢
            firstVideoOffset = CMTimeGetSeconds(CMTimeSubtract(pts, t0))
            lastPixelBuffer = pb
            lastVideoPTS = t0
            videoFrames += 1
            guard videoInput.isReadyForMoreMediaData else { return }
        }
        if adaptor.append(pb, withPresentationTime: pts) {
            if firstVideoOffset == nil { firstVideoOffset = CMTimeGetSeconds(CMTimeSubtract(pts, t0)) }
            lastPixelBuffer = pb
            lastVideoPTS = pts
            videoFrames += 1
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SCStream stopped with error: \(error)")
        onError?(error)
    }
}
