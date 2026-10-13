import Foundation

/// Volume and switches of one track.
struct TrackSettings: Codable, Equatable {
    var gainDB = 0.0
    var muted = false
    var solo = false
}

/// A sound the person put on the Music or Effects track.
struct UserClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var file: String           // absolute path
    var name: String
    var at: Double             // position in the edited recording, seconds
    var inPoint = 0.0          // where in the file the clip starts (trimmed beginning)
    var length: Double
    var fileDuration: Double
    var gainDB = 0.0
    var fadeIn = 0.0
    var fadeOut = 0.0

    var end: Double { at + length }
}

/// Processing of the voice: noise removal and "radio voice".
struct VoiceFX: Codable, Equatable {
    var denoise = "off"         // off, light, medium, strong
    var radio = false

    var isOn: Bool { denoise != "off" || radio }

    /// File name of the processed voice (made once, then reused).
    func fileName(fromStems: Bool) -> String {
        "voice-\(fromStems ? "stems" : "orig")-\(denoise)\(radio ? "-radio" : "").flac"
    }
}

/// Everything about tracks the person set: volumes, music and effects, ducking, voice.
struct Mix: Codable, Equatable {
    var tracks: [String: TrackSettings] = [:]
    var music: [UserClip] = []
    var effects: [UserClip] = []
    var duck = true             // music gets quieter while someone speaks
    var duckDepth = 12.0        // by this many dB
    var voice = VoiceFX()

    func settings(_ key: String) -> TrackSettings { tracks[key] ?? TrackSettings() }

    init() {}

    // edits saved by earlier versions lack newer fields: never lose them over that
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decodeIfPresent([String: TrackSettings].self, forKey: .tracks) ?? [:]
        music = try c.decodeIfPresent([UserClip].self, forKey: .music) ?? []
        effects = try c.decodeIfPresent([UserClip].self, forKey: .effects) ?? []
        duck = try c.decodeIfPresent(Bool.self, forKey: .duck) ?? true
        duckDepth = try c.decodeIfPresent(Double.self, forKey: .duckDepth) ?? 12
        voice = try c.decodeIfPresent(VoiceFX.self, forKey: .voice) ?? VoiceFX()
    }
}

/// One lane of the timeline and its pieces of audio, in the edited recording's time.
struct Lane: Identifiable {
    enum Kind: Hashable {
        case speaker(Int), background, music, effects
    }

    struct Clip: Equatable {
        var file: URL
        var src: Double          // where in the file
        var length: Double
        var at: Double           // where in the edited recording
        var gainDB = 0.0
        var fadeIn = 0.0
        var fadeOut = 0.0
        var userClip: UUID?      // music/effects clip the person can move
        var generated = false    // re-voiced by AI
        var tokens: ClosedRange<Int>?   // the words and sounds of a voice clip

        var end: Double { at + length }
    }

    var kind: Kind
    var clips: [Clip]
    var id: String { Lane.key(kind) }

    static func key(_ kind: Kind) -> String {
        switch kind {
        case .speaker(let n): return "speaker:\(n)"
        case .background: return "background"
        case .music: return "music"
        case .effects: return "effects"
        }
    }
}

/// Separated stems of a recording: the voice alone and everything else.
struct Stems {
    var voice: URL
    var background: URL

    static func found(in folder: URL) -> Stems? {
        let stems = Stems(voice: folder.appendingPathComponent("stems/voice.flac"),
                          background: folder.appendingPathComponent("stems/background.flac"))
        let fm = FileManager.default
        return fm.fileExists(atPath: stems.voice.path) && fm.fileExists(atPath: stems.background.path) ? stems : nil
    }
}

enum Timeline {
    /// The edited recording as lanes: one per speaker, the background (if separated),
    /// music and effects. Speaker lanes follow the text edits exactly.
    static func lanes(tokens: [Token], segments: [Segment], source: URL, stems: Stems?,
                      mix: Mix, speakerCount: Int, processedVoice: URL? = nil,
                      replacements: [Replacement] = [], arrangement: Arrangement = Arrangement()) -> [Lane] {
        var speakers: [Int: [Lane.Clip]] = [:]
        var background: [Lane.Clip] = []
        var crossfades: [(start: Double, end: Double, lead: Double, tail: Double)] = []
        let voiceFile = processedVoice ?? stems?.voice ?? source
        var clock = 0.0
        var index = 0
        for segment in segments {
            switch segment {
            case .original(let r):
                // split the kept piece where the speaker changes
                while index < tokens.count && tokens[index].end <= r.start + 0.0005 { index += 1 }
                var k = index
                var runStart = r.start, runFirst = index
                var runSpeaker = k < tokens.count ? (tokens[k].speaker ?? 0) : 0
                func close(at cut: Double, last: Int) {
                    var clip = Lane.Clip(file: voiceFile, src: runStart, length: cut - runStart, at: clock + runStart - r.start)
                    if runFirst <= last {
                        clip.tokens = runFirst...last
                        clip.gainDB = arrangement.gain(at: runFirst)
                    }
                    add(&speakers, runSpeaker, clip)
                }
                while k < tokens.count && tokens[k].start < r.end - 0.0005 {
                    let s = tokens[k].speaker ?? runSpeaker
                    if s != runSpeaker {
                        let cut = max(tokens[k].start, r.start)
                        close(at: cut, last: k - 1)
                        runStart = cut
                        runFirst = k
                        runSpeaker = s
                    }
                    k += 1
                }
                close(at: r.end, last: max(runFirst, k - 1))
                if let stems {
                    background.append(Lane.Clip(file: stems.background, src: r.start, length: r.end - r.start, at: clock))
                }
                clock += r.end - r.start
            case .generated(let url, let duration, let at):
                let first = Editing.tokenIndex(at: at + 0.0005, in: tokens) ?? 0
                let replaced = replacements.first { $0.first == first }
                let speaker = tokens.isEmpty ? 0 : tokens[first].speaker ?? 0
                // the piece overlaps its neighbours by its margins: they crossfade
                let lead = min(replaced?.lead ?? 0, clock), tail = replaced?.tail ?? 0
                var clip = Lane.Clip(file: url, src: (replaced?.lead ?? 0) - lead, length: lead + duration + tail,
                                     at: clock - lead, fadeIn: lead, fadeOut: tail, generated: true)
                clip.tokens = first...(replaced?.last ?? first)
                clip.gainDB = arrangement.gain(at: first)
                add(&speakers, speaker, clip)
                if lead > 0 || tail > 0 { crossfades.append((clock, clock + duration, lead, tail)) }
                clock += duration
            case .silence(let d):
                clock += d
            }
        }
        // the real voice fades out under the start of an AI piece and back in under its end
        for (n, list) in speakers {
            speakers[n] = list.map { c in
                guard !c.generated else { return c }
                var c = c
                for x in crossfades {
                    if abs(c.end - x.start) < 0.001 { c.fadeOut = max(c.fadeOut, x.lead) }
                    if abs(c.at - x.end) < 0.001 { c.fadeIn = max(c.fadeIn, x.tail) }
                }
                return c
            }
        }
        var lanes: [Lane] = (0..<max(speakerCount, 1)).map { Lane(kind: .speaker($0), clips: speakers[$0] ?? []) }
        if stems != nil { lanes.append(Lane(kind: .background, clips: background)) }
        lanes.append(Lane(kind: .music, clips: mix.music.map(userLaneClip)))
        lanes.append(Lane(kind: .effects, clips: mix.effects.map(userLaneClip)))
        return lanes
    }

    private static func add(_ dict: inout [Int: [Lane.Clip]], _ speaker: Int, _ clip: Lane.Clip) {
        guard clip.length > 0.0005 else { return }
        dict[speaker, default: []].append(clip)
    }

    private static func userLaneClip(_ c: UserClip) -> Lane.Clip {
        Lane.Clip(file: URL(fileURLWithPath: c.file), src: c.inPoint, length: c.length, at: c.at,
                  gainDB: c.gainDB, fadeIn: c.fadeIn, fadeOut: c.fadeOut, userClip: c.id)
    }

    /// Whether a track is heard, given mute and solo of all tracks.
    static func audible(_ key: String, in mix: Mix, keys: [String]) -> Bool {
        let anySolo = keys.contains { mix.settings($0).solo }
        let s = mix.settings(key)
        return !s.muted && (!anySolo || s.solo)
    }

    /// Length of the edited recording (speech plus any music/effects running past it).
    static func duration(_ lanes: [Lane]) -> Double {
        lanes.flatMap(\.clips).map(\.end).max() ?? 0
    }

    /// Original-recording time playing at time t of the edited recording (for highlighting
    /// words); a re-voiced piece reports the start of the words it replaced.
    static func originalTime(at t: Double, segments: [Segment]) -> Double? {
        var clock = 0.0
        for (n, segment) in segments.enumerated() {
            let d = segment.duration
            if t < clock + d {
                switch segment {
                case .original(let r): return r.start + (t - clock)
                case .generated(_, _, let at): return at
                case .silence:   // inserted silence: the words that come after it
                    for next in segments[(n + 1)...] {
                        if case .original(let r) = next { return r.start }
                        if case .generated(_, _, let at) = next { return at }
                    }
                    return nil
                }
            }
            clock += d
        }
        return nil
    }

    /// Edited-recording time of original time t, or nil if that moment was cut.
    static func editedTime(of t: Double, segments: [Segment]) -> Double? {
        var clock = 0.0
        for segment in segments {
            if case .original(let r) = segment, t >= r.start - 0.0005, t < r.end {
                return clock + max(0, t - r.start)
            }
            clock += segment.duration
        }
        return nil
    }

    /// Engine mixdown plan.
    static func plan(lanes: [Lane], mix: Mix, speech: [[Double]], sampleRate: Int, channels: Int,
                     loudness: String?, include: (Lane.Kind) -> Bool = { _ in true }) -> [String: Any] {
        let keys = lanes.map(\.id)
        var tracks: [[String: Any]] = []
        for lane in lanes where include(lane.kind) && audible(lane.id, in: mix, keys: keys) {
            var track: [String: Any] = [
                "gain_db": mix.settings(lane.id).gainDB,
                "clips": lane.clips.map { c -> [String: Any] in
                    ["file": c.file.path, "src": c.src, "length": c.length, "at": c.at,
                     "gain_db": c.gainDB, "fade_in": c.fadeIn, "fade_out": c.fadeOut]
                },
            ]
            if lane.kind == .music && mix.duck {
                track["duck"] = ["depth_db": mix.duckDepth, "speech": speech]
            }
            tracks.append(track)
        }
        var plan: [String: Any] = ["sample_rate": sampleRate, "channels": channels,
                                   "duration": duration(lanes), "tracks": tracks]
        if let loudness, loudness != "none" { plan["loudness"] = loudness }
        return plan
    }
}
