import AppKit
import AVFoundation

/// A vertical 9:16 video of a piece of the recording for Shorts / Reels / TikTok: the title on
/// top, big captions two or three words at a time with the spoken word in fire orange, and a
/// moving waveform. Drawn frame by frame with Core Graphics and encoded with the Mac's own
/// H.264 encoder — no neural networks, a minute of video takes about a minute.
enum ShortVideo {
    static let size = CGSize(width: 1080, height: 1920)
    static let fps: Int32 = 30

    struct Caption: Equatable {
        var words: [Subtitles.Word]
        var start: Double
        var end: Double
    }

    /// Words grouped into what is shown at once: up to three words / 18 letters, a new group
    /// after the end of a sentence; each group stays until the next one starts.
    static func captions(_ words: [Subtitles.Word]) -> [Caption] {
        var groups: [[Subtitles.Word]] = []
        var current: [Subtitles.Word] = []
        for w in words {
            let letters = (current + [w]).map(\.text.count).reduce(0, +)
            if !current.isEmpty && (current.count >= 3 || letters > 18) {
                groups.append(current)
                current = []
            }
            current.append(w)
            if let last = w.text.last, ".?!…".contains(last) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.enumerated().map { i, g in
            let next = i + 1 < groups.count ? groups[i + 1][0].start : (g.last!.end + 0.6)
            return Caption(words: g, start: g[0].start, end: max(g.last!.end, next))
        }
    }

    /// Loudness of the piece, one value 0…1 per video frame.
    static func envelope(_ audio: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: audio),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return [] }
        let step = Int(file.processingFormat.sampleRate) / Int(fps)
        var out: [Float] = []
        var i = 0
        while i + step <= Int(buffer.frameLength) {
            var sum: Float = 0
            for k in i..<(i + step) { sum += data[k] * data[k] }
            let db = 10 * log10(sum / Float(step) + 1e-10)
            out.append(min(1, max(0, (db + 45) / 40)))
            i += step
        }
        return out
    }

    /// Makes the video: `audio` is the piece itself (M4A/AAC), `words` are timed from its start.
    static func make(audio: URL, words: [Subtitles.Word], title: String, to output: URL,
                     onProgress: @escaping (Double) -> Void) async throws {
        let silent = output.deletingLastPathComponent().appendingPathComponent(".video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: silent) }
        let asset = AVURLAsset(url: audio)
        let duration = try await asset.load(.duration).seconds
        try await drawFrames(to: silent, duration: duration, words: words, title: title,
                             levels: envelope(audio)) { onProgress(0.9 * $0) }
        try await mux(video: silent, audio: asset, to: output)
        onProgress(1)
    }

    private static func drawFrames(to url: URL, duration: Double, words: [Subtitles.Word], title: String,
                                   levels: [Float], onProgress: (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EngineError.failed("video") }
        writer.startSession(atSourceTime: .zero)

        let captions = captions(words)
        let frames = Int((duration * Double(fps)).rounded(.up))
        for n in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                let t = Double(n) / Double(fps)
                draw(in: ctx, at: t, duration: duration, title: title, captions: captions, levels: levels, frame: n)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: fps))
            if n % 15 == 0 { onProgress(Double(n) / Double(frames)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EngineError.failed("video") }
    }

    private static func mux(video: URL, audio: AVURLAsset, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let duration = try await videoAsset.load(.duration)
        if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
           let into = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try into.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        if let track = try await audio.loadTracks(withMediaType: .audio).first,
           let into = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audio.load(.duration)
            try into.insertTimeRange(CMTimeRange(start: .zero, duration: min(duration, audioDuration)), of: track, at: .zero)
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw EngineError.failed(String(localized: "Не получилось собрать видео"))
        }
        try await export.export(to: output, as: .mp4)
    }

    // MARK: Drawing

    private static let bgTop = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.13, alpha: 1)
    private static let bgBottom = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.06, alpha: 1)

    private static func draw(in ctx: CGContext, at t: Double, duration: Double, title: String,
                             captions: [Caption], levels: [Float], frame: Int) {
        // the context has y up; draw text in a flipped AppKit context
        let gradient = CGGradient(colorsSpace: nil, colors: [bgTop.cgColor, bgBottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        // a soft fire glow behind the captions
        let glow = CGGradient(colorsSpace: nil, colors: [Theme.accent.withAlphaComponent(0.16).cgColor,
                                                        Theme.accent.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size.width / 2, y: size.height * 0.52), startRadius: 0,
                               endCenter: CGPoint(x: size.width / 2, y: size.height * 0.52), endRadius: 620, options: [])

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // title
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byWordWrapping
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: Theme.text, .paragraphStyle: titleStyle,
        ]).draw(with: CGRect(x: 90, y: 230, width: size.width - 180, height: 260),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        // captions
        if let caption = captions.last(where: { $0.start <= t + 0.02 }), t < caption.end + 0.3 {
            let line = NSMutableAttributedString()
            for (i, w) in caption.words.enumerated() {
                let spoken = t >= w.start - 0.02
                let current = spoken && (i == caption.words.count - 1 || t < caption.words[i + 1].start)
                line.append(NSAttributedString(string: (i > 0 ? " " : "") + w.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
                    .foregroundColor: current ? Theme.accent : spoken ? Theme.text : Theme.text.withAlphaComponent(0.45),
                ]))
            }
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = 6
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            // a short pop when a new group appears
            let pop = 1 + 0.06 * max(0, 1 - (t - caption.start) / 0.15)
            let box = CGRect(x: 70, y: 0, width: size.width - 140, height: 600)
            let height = line.boundingRect(with: box.size, options: [.usesLineFragmentOrigin]).height
            ctx.saveGState()
            ctx.translateBy(x: size.width / 2, y: size.height * 0.5)
            ctx.scaleBy(x: pop, y: pop)
            ctx.translateBy(x: -size.width / 2, y: -size.height * 0.5)
            line.draw(with: CGRect(x: box.minX, y: size.height * 0.5 - height / 2, width: box.width, height: height + 20),
                      options: [.usesLineFragmentOrigin])
            ctx.restoreGState()
        }
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        // waveform: the last ~1.3 s of loudness, mirrored from the middle
        let bars = 41, barWidth: CGFloat = 12, gap: CGFloat = 10
        let total = CGFloat(bars) * (barWidth + gap) - gap
        let baseY: CGFloat = 430
        ctx.setFillColor(Theme.accent.cgColor)
        for b in 0..<bars {
            let fromMiddle = abs(b - bars / 2)
            let k = frame - fromMiddle
            let level = k >= 0 && k < levels.count ? CGFloat(levels[k]) : 0
            let h = max(10, level * 220 * (1 - CGFloat(fromMiddle) / CGFloat(bars)))
            let x = (size.width - total) / 2 + CGFloat(b) * (barWidth + gap)
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: baseY - h / 2, width: barWidth, height: h),
                               cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        }
        ctx.fillPath()
        // progress line
        ctx.setFillColor(Theme.text.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: 90, y: 250, width: size.width - 180, height: 6))
        ctx.setFillColor(Theme.accent.cgColor)
        ctx.fill(CGRect(x: 90, y: 250, width: (size.width - 180) * CGFloat(min(1, t / max(duration, 0.01))), height: 6))
    }
}
