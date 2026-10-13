import Foundation

/// Subtitles for the edited recording, timed to the exported file.
enum Subtitles {
    /// The mixdown puts every piece at its exact time (soft edges, no overlapping
    /// crossfades), so joins don't shift anything.
    static let joinOverlap = 0.0
    static let maxChars = 42       // one line on a phone screen
    static let maxSeconds = 5.0
    static let pauseBreak = 0.6    // a longer silence starts a new subtitle

    struct Word: Equatable {
        var text: String
        var start: Double
        var end: Double
        var speaker: Int?
    }

    struct Cue: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Words that remain after editing, with their times in the edited recording.
    static func words(tokens: [Token], states: [TokenState], segments: [Segment],
                      replacements: [Replacement]) -> [Word] {
        let replaced = Set(replacements.flatMap { Array($0.first...$0.last) })
        var out: [Word] = []
        var clock = 0.0
        var tokenIndex = 0
        for (n, segment) in segments.enumerated() {
            if n > 0 { clock -= joinOverlap }
            switch segment {
            case .silence(let d):
                clock += d
            case .generated(_, let duration, let at):
                if let r = replacements.first(where: { abs(tokens[$0.first].start - at) < 0.0005 }) {
                    out.append(Word(text: r.text, start: clock, end: clock + duration, speaker: tokens[r.first].speaker))
                }
                clock += duration
            case .original(let r):
                while tokenIndex < tokens.count && tokens[tokenIndex].end <= r.start + 0.0005 { tokenIndex += 1 }
                var i = tokenIndex
                while i < tokens.count && tokens[i].start < r.end - 0.0005 {
                    let t = tokens[i]
                    if t.isWord, states[i] == .keep, !replaced.contains(i), let text = t.text,
                       t.start >= r.start - 0.0005, t.end <= r.end + 0.0005 {
                        out.append(Word(text: text, start: clock + t.start - r.start,
                                        end: clock + t.end - r.start, speaker: t.speaker))
                    }
                    i += 1
                }
                clock += r.end - r.start
            }
        }
        return out
    }

    /// Groups words into readable subtitles: short lines, new one after a sentence end,
    /// a pause or a change of speaker.
    static func cues(_ words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(Cue(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for w in words {
            if let last = current.last, let first = current.first {
                let text = (current.map(\.text) + [w.text]).joined(separator: " ")
                let sentenceEnd = last.text.last.map { ".?!…".contains($0) } ?? false
                if text.count > maxChars || w.end - first.start > maxSeconds || w.start - last.end > pauseBreak
                    || w.speaker != last.speaker || (sentenceEnd && current.count >= 3) {
                    flush()
                }
            }
            current.append(w)
        }
        flush()
        // never show a subtitle shorter than 0.7 s or overlapping the next one
        for i in cues.indices {
            let limit = i + 1 < cues.count ? cues[i + 1].start : cues[i].end + 0.7
            cues[i].end = min(max(cues[i].end, cues[i].start + 0.7), limit)
        }
        return cues
    }

    /// The edited text as lines "[m:ss] …" (about every 30 s), for the language model.
    static func script(_ words: [Word]) -> String {
        var lines: [String] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first else { return }
            let s = Int(first.start)
            let stamp = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                                  : String(format: "%d:%02d", s / 60, s % 60)
            lines.append("[\(stamp)] " + current.map(\.text).joined(separator: " "))
            current = []
        }
        for w in words {
            if let first = current.first, w.start - first.start > 30,
               let last = current.last?.text.last, ".?!…".contains(last) {
                flush()
            }
            current.append(w)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// The edited text as a document: a paragraph whenever the speaker changes or there is a
    /// long pause; "[1:05] Имя: …" when time codes and names are wanted.
    static func document(_ words: [Word], names: [String]?, timecodes: Bool) -> String {
        var paragraphs: [String] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first else { return }
            var head = ""
            if timecodes { head += "[\(Format.time(first.start))] " }
            if let names, let speaker = first.speaker, names.indices.contains(speaker) { head += "\(names[speaker]): " }
            var text = ""
            for w in current { text += (text.isEmpty || w.text.first.map { "-.,!?…:;)»".contains($0) } == true ? "" : " ") + w.text }
            paragraphs.append(head + text)
            current = []
        }
        for w in words {
            if let last = current.last, w.speaker != last.speaker || w.start - last.end > 1.5 { flush() }
            current.append(w)
        }
        flush()
        return paragraphs.joined(separator: "\n\n") + "\n"
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(stamp(c.start, ",")) --> \(stamp(c.end, ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(stamp($0.start, ".")) --> \(stamp($0.end, "."))\n\($0.text)\n" }
            .joined(separator: "\n")
    }

    /// 3725.5 -> "01:02:05,500"
    static func stamp(_ t: Double, _ separator: String) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60,
                      separator, ms % 1000)
    }
}
