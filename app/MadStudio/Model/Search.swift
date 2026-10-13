import Foundation

/// Finding words and phrases in the transcript (⌘F): case and «ё» don't matter, punctuation is
/// ignored, the last word may be unfinished ("подк" finds "подкаст") — so results show up while
/// typing. A match covers everything from its first to its last word, pauses and breaths
/// between them included, so «Вырезать все» removes the phrase cleanly.
enum TranscriptSearch {
    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func matches(_ query: String, in tokens: [Token]) -> [ClosedRange<Int>] {
        let wanted = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return [] }
        // the words of the transcript, in order, with their token index
        let words: [(index: Int, text: String)] = tokens.indices.compactMap { i in
            guard tokens[i].isWord, let text = tokens[i].text else { return nil }
            let n = normalize(text)
            return n.isEmpty ? nil : (i, n)
        }
        guard words.count >= wanted.count else { return [] }
        var out: [ClosedRange<Int>] = []
        var w = 0
        while w + wanted.count <= words.count {
            let fits = wanted.indices.allSatisfy { k in
                let word = words[w + k].text
                return k == wanted.count - 1 ? word.hasPrefix(wanted[k]) : word == wanted[k]
            }
            if fits {
                out.append(words[w].index...words[w + wanted.count - 1].index)
                w += wanted.count
            } else {
                w += 1
            }
        }
        return out
    }
}
