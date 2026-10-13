import XCTest
@testable import MadStudio

final class SearchTests: XCTestCase {
    private func words(_ text: String) -> [Token] {
        var t = 0.0
        return text.split(separator: " ").map { w in
            defer { t += 0.5 }
            return w == "|" ? Token(kind: .pause, start: t, end: t + 0.5)
                            : Token(kind: .word, start: t, end: t + 0.5, text: String(w))
        }
    }

    func testFindsWordsIgnoringCaseYoAndPunctuation() {
        let tokens = words("Значит, всё ясно. А значит ВСЕ")
        XCTAssertEqual(TranscriptSearch.matches("значит", in: tokens), [0...0, 4...4])
        XCTAssertEqual(TranscriptSearch.matches("все", in: tokens).count, 2)   // «всё» and «ВСЕ»
    }

    func testPhraseCoversPausesBetweenItsWords() {
        let tokens = words("ну как | бы да как бы")
        XCTAssertEqual(TranscriptSearch.matches("как бы", in: tokens), [1...3, 5...6])
    }

    func testLastWordMayBeUnfinished() {
        let tokens = words("записываю подкаст дома")
        XCTAssertEqual(TranscriptSearch.matches("подк", in: tokens), [1...1])
        XCTAssertEqual(TranscriptSearch.matches("подк дома", in: tokens), [])   // only the last word is a prefix
        XCTAssertEqual(TranscriptSearch.matches("   ", in: tokens), [])
    }
}
