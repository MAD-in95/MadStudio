import Foundation

/// Habits of each speaker: pace, "э-э", pauses and parasite words.
struct SpeechStats {
    struct Speaker {
        var id: Int
        var speakingTime: Double = 0     // seconds of words
        var words = 0
        var fillers = 0                  // "э-э", "мм"
        var pauseTime = 0.0              // pauses longer than half a second
        var longestPause = 0.0
        var parasites: [String: Int] = [:]

        /// Words per minute of actual speech (pauses not counted).
        var pace: Int { speakingTime > 0 ? Int((Double(words) / speakingTime * 60).rounded()) : 0 }
        var fillersPerMinute: Double { speakingTime > 0 ? Double(fillers) / speakingTime * 60 : 0 }
    }

    var speakers: [Speaker]
    var takes: Int

    /// Common Russian and English filler words and phrases; multi-word ones are matched as phrases.
    static let parasiteWords = ["ну", "вот", "типа", "короче", "значит", "как бы", "в общем", "это самое",
                                "так сказать", "собственно", "получается", "блин", "чисто", "реально", "прям",
                                "like", "basically", "actually", "literally", "you know", "i mean", "kind of", "sort of"]

    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0 == "-" }
    }

    init(tokens: [Token]) {
        var bySpeaker: [Int: Speaker] = [:]
        var takeIds = Set<Int>()
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            let id = t.speaker ?? 0
            var s = bySpeaker[id] ?? Speaker(id: id)
            if let take = t.take { takeIds.insert(take) }
            switch t.kind {
            case .word:
                s.words += 1
                s.speakingTime += t.duration
                if t.parasite == true { s.fillers += 1 }
                for phrase in Self.parasiteWords {
                    let parts = phrase.split(separator: " ").map(String.init)
                    guard i + parts.count <= tokens.count else { continue }
                    let window = Self.words(from: i, count: parts.count, in: tokens)
                    if window == parts { s.parasites[phrase, default: 0] += 1 }
                }
            case .filler:
                s.fillers += 1
            case .pause where t.duration > 0.5:
                s.pauseTime += t.duration
                s.longestPause = max(s.longestPause, t.duration)
            default:
                break
            }
            bySpeaker[id] = s
            i += 1
        }
        speakers = bySpeaker.values.filter { $0.words > 0 }.sorted { $0.id < $1.id }
        takes = takeIds.count
    }

    /// The next `count` words starting at token i (skipping pauses and sounds), normalized.
    static func words(from i: Int, count: Int, in tokens: [Token]) -> [String] {
        var out: [String] = []
        var k = i
        while k < tokens.count && out.count < count {
            if tokens[k].isWord, let text = tokens[k].text { out.append(normalized(text)) }
            k += 1
        }
        return out
    }

    /// Token indices of every occurrence of a parasite word/phrase (all of its words).
    static func occurrences(of phrase: String, in tokens: [Token]) -> [Int] {
        let parts = phrase.split(separator: " ").map(String.init)
        var out: [Int] = []
        for i in tokens.indices where tokens[i].isWord {
            var found: [Int] = []
            var k = i
            while k < tokens.count && found.count < parts.count {
                if tokens[k].isWord, let text = tokens[k].text {
                    guard normalized(text) == parts[found.count] else { break }
                    found.append(k)
                }
                k += 1
            }
            if found.count == parts.count { out += found }
        }
        return out
    }
}
