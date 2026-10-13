import Foundation

enum TokenKind: String, Codable {
    case word, pause, breath, filler, click
    /// Speech that is not in the transcript: a repeat or the other person's short reply.
    case speech

    init(from decoder: Decoder) throws {
        // kinds added by newer engines are shown as speech, which is never auto-removed
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TokenKind(rawValue: raw) ?? .speech
    }
}

/// One piece of the timeline: a word or a sound Whisper left out. Tokens tile the whole recording.
struct Token: Codable, Equatable {
    var kind: TokenKind
    var start: Double
    var end: Double
    var text: String?
    var prob: Double?
    var para: Bool?
    var parasite: Bool?
    var stretched: Bool?
    /// Failed take: an attempt that was said again right after. Same number = same attempt.
    var take: Int?
    /// Who is speaking: 0, 1, … in order of first appearance.
    var speaker: Int?

    var duration: Double { end - start }
    var isWord: Bool { kind == .word }
    /// Sounds the cleanup removes: breaths, "э-э", clicks and parasite words like "ээ".
    var isNoise: Bool { kind == .breath || kind == .filler || kind == .click || parasite == true }
}

struct Transcript: Codable {
    var version: Int
    var source: String
    var duration: Double
    var language: String
    var model: String
    var secondsSpent: Double?
    var speakers: SpeakerInfo?
    var tokens: [Token]

    struct SpeakerInfo: Codable {
        var count: Int
        var seconds: [String: Double]?
    }

    enum CodingKeys: String, CodingKey {
        case version, source, duration, language, model, tokens, speakers
        case secondsSpent = "seconds_spent"
    }
}

enum TokenState: String, Codable {
    case keep, delete, shorten
}

/// Words re-voiced by the AI: tokens first...last are replaced by a generated audio file.
struct Replacement: Codable, Equatable, Identifiable {
    var id = UUID()
    var first: Int
    var last: Int
    var text: String
    var file: String        // file name inside the project folder
    var duration: Double    // the new words themselves
    /// the file also holds this much of the voice before and after (overlapped with the
    /// recording and crossfaded, so the AI voice flows into the real one)
    var lead: Double?
    var tail: Double?
    /// pace the person set afterwards (1 — as generated)
    var speed: Double?
}

/// One piece of the edited recording, in playback order.
enum Segment: Equatable {
    case original(TimeRange)
    /// generated audio that stands at original time `at`
    case generated(file: URL, duration: Double, at: Double)
    /// silence put in on the timeline (a voice clip moved to the right further than its pause)
    case silence(Double)

    var duration: Double {
        switch self {
        case .original(let r): return r.end - r.start
        case .generated(_, let d, _): return d
        case .silence(let d): return d
        }
    }
}

/// Edits made with the mouse on the timeline, on top of the text edits. The text and the
/// sound stay in step: these only change pauses, cut points and volumes.
struct Arrangement: Codable, Equatable {
    /// extra silence (seconds) before token i: a clip moved further right than its pause allows
    var gaps: [Int: Double] = [:]
    /// how much of a pause token is kept (seconds), set by moving a clip
    var pauses: [Int: Double] = [:]
    /// clips are cut before these tokens (razor), even in continuous speech
    var splits: Set<Int> = []
    /// volume of stretches of speech
    var gains: [ClipGain] = []

    var isEmpty: Bool { gaps.isEmpty && pauses.isEmpty && splits.isEmpty && gains.isEmpty }

    func gain(at token: Int) -> Double {
        gains.first { $0.first <= token && token <= $0.last }?.db ?? 0
    }

    /// Tokens before which a clip must end (cuts and volume borders).
    var breaks: Set<Int> {
        splits.union(gains.flatMap { [$0.first, $0.last + 1] })
    }
}

/// Tokens first...last play db louder (or quieter).
struct ClipGain: Codable, Equatable {
    var first: Int
    var last: Int
    var db: Double
}

struct TimeRange: Codable, Equatable {
    var start: Double
    var end: Double
}

struct CleanOptions: Codable, Equatable {
    var pauses = true
    var maxPause = 0.7      // pauses longer than this get shortened...
    var keepPause = 0.4     // ...to this length
    var breaths = true
    var fillers = true
    var clicks = false
    var takes = false       // failed takes are only suggested unless the user turns this on

    init() {}

    // options saved by older versions lack newer fields
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CleanOptions()
        pauses = try c.decodeIfPresent(Bool.self, forKey: .pauses) ?? d.pauses
        maxPause = try c.decodeIfPresent(Double.self, forKey: .maxPause) ?? d.maxPause
        keepPause = try c.decodeIfPresent(Double.self, forKey: .keepPause) ?? d.keepPause
        breaths = try c.decodeIfPresent(Bool.self, forKey: .breaths) ?? d.breaths
        fillers = try c.decodeIfPresent(Bool.self, forKey: .fillers) ?? d.fillers
        clicks = try c.decodeIfPresent(Bool.self, forKey: .clicks) ?? d.clicks
        takes = try c.decodeIfPresent(Bool.self, forKey: .takes) ?? d.takes
    }
}

/// The transcript format this app understands fully; older ones are upgraded by the engine.
let currentTranscriptVersion = 2
