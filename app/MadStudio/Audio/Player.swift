import AVFoundation
import Observation

/// Plays the edited recording track by track (speakers, background, music, effects), in
/// sync, with track volumes and music ducking — or the untouched original.
@Observable
@MainActor
final class Player {
    private(set) var isPlaying = false
    /// Edited-recording time while playing the edit; original time while playing the original.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var playingOriginal = false
    /// Length of the original recording.
    private(set) var originalDuration: Double = 0

    private let engine = AVAudioEngine()
    private var source: URL?
    private var files: [URL: AVAudioFile] = [:]
    private var nodes: [String: AVAudioPlayerNode] = [:]
    /// node key -> track key, so volumes can follow sliders while playing
    private var nodeTrack: [String: String] = [:]
    private var nodeClipGain: [String: Double] = [:]
    private var mix = Mix()
    private var trackKeys: [String] = []
    private var speech: [[Double]] = []
    private var startTime: Double = 0
    private var startHost: UInt64 = 0
    private var endTime: Double = 0
    private var timer: Timer?

    func load(_ url: URL) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        source = url
        files = [url: file]
        originalDuration = Double(file.length) / file.processingFormat.sampleRate
        duration = originalDuration
        currentTime = 0
    }

    /// Plays the edit from edited time t.
    func play(from t: Double, lanes: [Lane], mix: Mix, speech: [[Double]]) {
        stopNodes()
        playingOriginal = false
        self.mix = mix
        self.speech = speech
        trackKeys = lanes.map(\.id)
        duration = Timeline.duration(lanes)
        var used: [AVAudioPlayerNode] = []
        for lane in lanes {
            for clip in lane.clips where clip.end > t {
                guard let file = file(clip.file) else { continue }
                // music and effects clips each get a node (own volume); speakers share one per file
                // (a voice clip with its own volume gets its own node too)
                let key = clip.userClip.map { "\(lane.id)|\($0)" } ?? "\(lane.id)|\(clip.file.path)|\(clip.gainDB)"
                let node = node(key, format: file.processingFormat)
                nodeTrack[key] = lane.id
                nodeClipGain[key] = clip.gainDB
                if schedule(clip, from: file, on: node, playheadAt: t), !used.contains(node) { used.append(node) }
            }
        }
        begin(at: t, end: duration, nodes: used)
    }

    /// Plays the untouched original from original time t.
    func playOriginal(from t: Double) {
        stopNodes()
        playingOriginal = true
        duration = originalDuration
        guard let source, let file = file(source) else { return }
        let node = node("original", format: file.processingFormat)
        nodeTrack["original"] = nil
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(t * rate)
        guard start < file.length else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil)
        begin(at: t, end: originalDuration, nodes: [node])
    }

    /// Track volumes changed (slider, mute, solo) — applied right away while playing.
    func update(mix: Mix) {
        self.mix = mix
        applyVolumes()
    }

    func pause() {
        stopNodes()
        isPlaying = false
    }

    func stop() {
        pause()
    }

    /// Moves the playhead without playing.
    func seek(to t: Double) {
        currentTime = max(0, min(t, duration))
    }

    // MARK: Internals

    /// Puts a clip on a node, from playback position t. Fade-in and fade-out parts are
    /// played as small buffers with the volume ramped (music fades, AI-voice crossfades);
    /// the rest straight from the file.
    private func schedule(_ clip: Lane.Clip, from file: AVAudioFile, on node: AVAudioPlayerNode, playheadAt t: Double) -> Bool {
        let rate = file.processingFormat.sampleRate
        let fadeIn = min(clip.fadeIn, clip.length / 2), fadeOut = min(clip.fadeOut, clip.length / 2)
        // clip-local stretches: (from, to, volume at from, volume at to)
        let parts: [(Double, Double, Float, Float)] = [
            (0, fadeIn, 0, 1), (fadeIn, clip.length - fadeOut, 1, 1), (clip.length - fadeOut, clip.length, 1, 0),
        ]
        var scheduled = false
        for (a, b, va, vb) in parts where b - a > 0.0005 {
            let from = max(a, t - clip.at)
            guard from < b else { continue }
            let start = AVAudioFramePosition((clip.src + from) * rate)
            guard start < file.length else { continue }
            let count = min(AVAudioFrameCount((b - from) * rate), AVAudioFrameCount(file.length - start))
            guard count > 0 else { continue }
            let when = AVAudioTime(sampleTime: AVAudioFramePosition(max(0, clip.at + from - t) * rate), atRate: rate)
            if va == 1 && vb == 1 {
                node.scheduleSegment(file, startingFrame: start, frameCount: count, at: when)
            } else {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { continue }
                file.framePosition = start
                guard (try? file.read(into: buffer, frameCount: count)) != nil, let data = buffer.floatChannelData else { continue }
                let n = Int(buffer.frameLength), span = Float(max(1, (b - a) * rate))
                let offset = Float((from - a) * rate)
                for ch in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<n {
                        let x = min(1, (offset + Float(i)) / span)
                        data[ch][i] *= va + (vb - va) * x
                    }
                }
                node.scheduleBuffer(buffer, at: when)
            }
            scheduled = true
        }
        return scheduled
    }

    private func file(_ url: URL) -> AVAudioFile? {
        if let f = files[url] { return f }
        let f = try? AVAudioFile(forReading: url)
        files[url] = f
        return f
    }

    private func node(_ key: String, format: AVAudioFormat) -> AVAudioPlayerNode {
        if let n = nodes[key], n.outputFormat(forBus: 0) == format { return n }
        if let old = nodes[key] { engine.detach(old) }
        let n = AVAudioPlayerNode()
        engine.attach(n)
        engine.connect(n, to: engine.mainMixerNode, format: format)
        nodes[key] = n
        return n
    }

    private func begin(at t: Double, end: Double, nodes used: [AVAudioPlayerNode]) {
        guard !used.isEmpty else { return pause() }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            return pause()
        }
        applyVolumes()
        // all tracks start at the same moment, a little ahead so scheduling is done
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.08)
        for n in used { n.play(at: AVAudioTime(hostTime: host)) }
        startTime = t
        startHost = host
        endTime = end
        currentTime = t
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopNodes() {
        timer?.invalidate()
        timer = nil
        for n in nodes.values { n.stop() }
    }

    private func applyVolumes() {
        for (key, node) in nodes {
            guard let track = nodeTrack[key] else { node.volume = 1; continue }
            let s = mix.settings(track)
            let audible = Timeline.audible(track, in: mix, keys: trackKeys)
            node.volume = audible ? Float(pow(10, (s.gainDB + (nodeClipGain[key] ?? 0)) / 20)) : 0
        }
    }

    private func tick() {
        let now = mach_absolute_time()
        let elapsed = now > startHost ? AVAudioTime.seconds(forHostTime: now - startHost) : 0
        currentTime = min(startTime + elapsed, endTime)
        if !playingOriginal && mix.duck { applyDucking() }
        if currentTime >= endTime - 0.01 { pause() }
    }

    /// Music volume follows speech while playing (the export does the same, smoother).
    private func applyDucking() {
        let low = pow(10, -mix.duckDepth / 20)
        let speaking = speech.contains { currentTime >= $0[0] - 0.2 && currentTime <= $0[1] + 0.5 }
        for (key, node) in nodes where nodeTrack[key] == "music" {
            let s = mix.settings("music")
            guard Timeline.audible("music", in: mix, keys: trackKeys) else { continue }
            let base = pow(10, (s.gainDB + (nodeClipGain[key] ?? 0)) / 20)
            let target = Float(base * (speaking ? low : 1))
            node.volume += (target - node.volume) * (speaking ? 0.35 : 0.08)   // fast down, slow up
        }
    }
}
