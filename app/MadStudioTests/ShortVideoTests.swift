import XCTest
@testable import MadStudio

final class ShortVideoTests: XCTestCase {
    private func words(_ text: String) -> [Subtitles.Word] {
        text.split(separator: " ").enumerated().map { i, w in
            Subtitles.Word(text: String(w), start: Double(i) * 0.5, end: Double(i) * 0.5 + 0.4, speaker: 0)
        }
    }

    func testCaptionsHoldUpToThreeWordsAndBreakAtSentences() {
        let groups = ShortVideo.captions(words("Привет всем. Сегодня мы говорим о звуке дома"))
        XCTAssertEqual(groups.map { $0.words.map(\.text).joined(separator: " ") },
                       ["Привет всем.", "Сегодня мы говорим", "о звуке дома"])
    }

    func testEachCaptionStaysUntilTheNextOne() {
        let groups = ShortVideo.captions(words("раз два три четыре"))
        XCTAssertEqual(groups[0].end, groups[1].start)
        XCTAssertGreaterThan(groups.last!.end, groups.last!.words.last!.end)
    }

    func testLongWordsMakeShorterGroups() {
        let groups = ShortVideo.captions(words("достопримечательности восхитительные невероятно"))
        XCTAssertTrue(groups.allSatisfy { $0.words.count <= 2 })
    }
}
