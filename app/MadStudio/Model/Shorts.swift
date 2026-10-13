import Foundation

/// A piece of the recording that could be posted on its own as a Short / Reel.
/// Times are in the ORIGINAL recording, so the moment stays in place after later edits.
struct ShortMoment: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var title: String
    var why: String
    var score: Double
    var text: String

    /// "сильный" / "хороший" / "неплохой" — how the language model rated it.
    var grade: String {
        score >= 8 ? String(localized: "сильный") : score >= 7 ? String(localized: "хороший") : String(localized: "неплохой")
    }
}

enum Shorts {
    static func fileURL(in folder: URL) -> URL {
        folder.appendingPathComponent("shorts.json")
    }

    static func load(from folder: URL) -> [ShortMoment] {
        (try? Data(contentsOf: fileURL(in: folder)))
            .flatMap { try? JSONDecoder().decode([ShortMoment].self, from: $0) } ?? []
    }

    static func save(_ moments: [ShortMoment], to folder: URL) {
        if let data = try? JSONEncoder().encode(moments) {
            try? data.write(to: fileURL(in: folder))
        }
    }

    /// The edited recording's words for the engine (times in the edited recording).
    static func wordsJSON(_ words: [Subtitles.Word]) throws -> Data {
        let list: [[String: Any]] = words.map { w in
            var d: [String: Any] = ["text": w.text, "start": w.start, "end": w.end]
            if let s = w.speaker { d["speaker"] = s }
            return d
        }
        return try JSONSerialization.data(withJSONObject: list)
    }

    /// Moments found by the engine (edited times) -> moments kept in original time.
    static func moments(fromEngine data: Data, segments: [Segment]) throws -> [ShortMoment] {
        struct Found: Decodable {
            var start: Double, end: Double, title: String, why: String, score: Double, text: String
        }
        struct Answer: Decodable { var moments: [Found] }
        return try JSONDecoder().decode(Answer.self, from: data).moments.compactMap { f in
            guard let a = Timeline.originalTime(at: f.start, segments: segments),
                  let b = Timeline.originalTime(at: max(f.start, f.end - 0.001), segments: segments) else { return nil }
            return ShortMoment(start: a, end: b, title: f.title, why: f.why, score: f.score, text: f.text)
        }
    }

    /// Where a moment is in the edited recording now (nil if it was cut out entirely).
    static func edited(_ m: ShortMoment, segments: [Segment]) -> ClosedRange<Double>? {
        let a = Timeline.editedTimeOrNext(of: m.start, segments: segments)
        let b = Timeline.editedTimeOrNext(of: m.end, segments: segments)
        return b - a > 0.5 ? a...b : nil
    }

    /// A file name from a moment's title (no characters the Finder dislikes).
    static func fileName(_ base: String, number: Int, title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let short = String(clean.prefix(60))
        return "\(base) — Shorts \(number)" + (short.isEmpty ? "" : " — \(short)")
    }

    /// Subtitles for one stretch of the edited recording, timed from its start.
    static func cues(_ words: [Subtitles.Word], in range: ClosedRange<Double>) -> [Subtitles.Cue] {
        Subtitles.cues(self.words(words, in: range))
    }

    /// The words inside a piece, timed from the piece's start.
    static func words(_ words: [Subtitles.Word], in range: ClosedRange<Double>) -> [Subtitles.Word] {
        words.filter { $0.start >= range.lowerBound - 0.05 && $0.end <= range.upperBound + 0.05 }
            .map { w -> Subtitles.Word in
                var w = w
                w.start = max(0, w.start - range.lowerBound)
                w.end = min(range.upperBound, w.end) - range.lowerBound
                return w
            }
    }
}

extension Timeline {
    /// Edited time of original time t; a cut moment maps to where the recording continues.
    static func editedTimeOrNext(of t: Double, segments: [Segment]) -> Double {
        if let e = editedTime(of: t, segments: segments) { return e }
        var clock = 0.0
        for segment in segments {
            switch segment {
            case .original(let r) where r.start >= t: return clock
            case .generated(_, _, let at) where at >= t - 0.0005: return clock
            default: break
            }
            clock += segment.duration
        }
        return clock
    }

    /// Only the stretch `range` of the lanes, moved to start at 0 (to save one piece).
    /// Music cut in the middle gets short fades so it doesn't start or stop abruptly.
    static func trim(_ lanes: [Lane], to range: ClosedRange<Double>) -> [Lane] {
        lanes.map { lane in
            var out = lane
            out.clips = lane.clips.compactMap { c in
                let a = max(c.at, range.lowerBound), b = min(c.end, range.upperBound)
                guard b - a > 0.001 else { return nil }
                var clip = c
                clip.src = c.src + (a - c.at)
                clip.at = a - range.lowerBound
                clip.length = b - a
                let cutStart = a > c.at + 0.001, cutEnd = b < c.end - 0.001
                if lane.kind == .music || lane.kind == .background || lane.kind == .effects {
                    clip.fadeIn = cutStart ? min(0.5, clip.length / 2) : min(c.fadeIn, clip.length / 2)
                    clip.fadeOut = cutEnd ? min(1.0, clip.length / 2) : min(c.fadeOut, clip.length / 2)
                }
                return clip
            }
            return out
        }
    }

    /// Speech moments inside `range`, moved to start at 0.
    static func trim(speech: [[Double]], to range: ClosedRange<Double>) -> [[Double]] {
        speech.compactMap { s in
            let a = max(s[0], range.lowerBound), b = min(s[1], range.upperBound)
            return b > a ? [a - range.lowerBound, b - range.lowerBound] : nil
        }
    }
}
