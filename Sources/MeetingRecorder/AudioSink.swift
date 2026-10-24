import AVFoundation
import CoreMedia

/// 把 SCStream 送來的 PCM 音訊寫成 CAF 檔。
///
/// 三個重點：
/// 1. 格式在第一個 buffer 到時才決定（麥克風是裝置原生格式，事先不知道）。
/// 2. 時間軸對齊錄製起點 t0：開頭和中途若有空檔（例如系統沒聲音時不送 buffer），
///    補上靜音，讓檔案第 N 秒永遠對應錄製的第 N 秒。
/// 3. 格式中途改變（換麥克風、藍牙耳機切到通話模式）時，轉換回檔案原本的格式繼續寫。
final class AudioSink {
    let url: URL
    let t0: CMTime
    private(set) var firstOffset: Double?
    private(set) var framesWritten: AVAudioFramePosition = 0
    private(set) var warnings: [String] = []
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(url: URL, t0: CMTime) {
        self.url = url
        self.t0 = t0
    }

    var hasData: Bool { framesWritten > 0 }

    func append(_ sb: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sb), let desc = sb.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0 else { return }
        var asbd = asbdPtr.pointee
        guard let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        if file == nil {
            do {
                file = try AVAudioFile(forWriting: url, settings: srcFormat.settings,
                                       commonFormat: srcFormat.commonFormat, interleaved: srcFormat.isInterleaved)
                format = srcFormat
            } catch {
                NSLog("AudioSink: 無法建立 \(url.lastPathComponent): \(error)")
                return
            }
        }
        guard let file, let format else { return }

        guard var pcm = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let offset = CMTimeGetSeconds(CMTimeSubtract(pts, t0))

        if !srcFormat.isEqual(format) {
            guard let converted = convert(pcm, from: srcFormat, to: format, at: offset) else { return }
            pcm = converted
        } else if converter != nil {
            // 切回原格式：丟掉舊 converter（裡面可能殘留幾十幀），下次再切換時重新建立並記錄
            converter = nil
            converterSource = nil
        }

        // 依時間戳補靜音
        if firstOffset == nil { firstOffset = offset }
        if offset.isFinite, offset >= 0, offset < 6 * 3600 {
            let expected = AVAudioFramePosition(offset * format.sampleRate)
            let gap = expected - framesWritten
            if gap > AVAudioFramePosition(format.sampleRate * 0.03) {
                writeSilence(frames: gap)
            }
        }

        do {
            try file.write(from: pcm)
            framesWritten += AVAudioFramePosition(pcm.frameLength)
        } catch {
            NSLog("AudioSink: 寫入失敗 \(error)")
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, from src: AVAudioFormat, to dst: AVAudioFormat,
                         at offset: Double) -> AVAudioPCMBuffer? {
        if converter == nil || !(converterSource?.isEqual(src) ?? false) {
            converter = AVAudioConverter(from: src, to: dst)
            converterSource = src
            let msg = String(format: "第 %.0f 秒起裝置格式改為 %.0f Hz／%d 聲道，已自動轉換",
                             offset, src.sampleRate, Int(src.channelCount))
            warnings.append(msg)
            NSLog("AudioSink: \(url.lastPathComponent) \(msg)")
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * dst.sampleRate / src.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    /// 停止時把尾端補到 duration，讓各軌長度一致。
    func finish(duration: Double) {
        if let format, file != nil {
            let gap = AVAudioFramePosition(duration * format.sampleRate) - framesWritten
            if gap > 0 { writeSilence(frames: gap) }
        }
        file = nil  // AVAudioFile 在釋放時關檔
    }

    private func writeSilence(frames total: AVAudioFramePosition) {
        guard let file, let format else { return }
        var remaining = total
        let chunk: AVAudioFrameCount = 48_000
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        // 新配置的 buffer 內容不保證為 0，手動清零（先設滿長度，mDataByteSize 才是整塊）
        buf.frameLength = chunk
        let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        while remaining > 0 {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            buf.frameLength = n
            do { try file.write(from: buf) } catch { return }
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }
}
