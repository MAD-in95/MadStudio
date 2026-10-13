import XCTest
@testable import MadStudio

final class SpeechStatsTests: XCTestCase {
    private func w(_ text: String, _ start: Double, speaker: Int = 0) -> Token {
        Token(kind: .word, start: start, end: start + 0.5, text: text, speaker: speaker)
    }

    func testCountsParasitesAndPace() {
        let tokens = [w("Ну,", 0), w("как", 0.5), w("бы", 1), w("вот", 1.5),
                      Token(kind: .filler, start: 2, end: 2.4, speaker: 0),
                      Token(kind: .pause, start: 2.4, end: 3.6, speaker: 0), w("ну", 3.6)]
        let s = SpeechStats(tokens: tokens).speakers[0]
        XCTAssertEqual(s.words, 5)
        XCTAssertEqual(s.parasites["ну"], 2)
        XCTAssertEqual(s.parasites["как бы"], 1)
        XCTAssertEqual(s.parasites["вот"], 1)
        XCTAssertEqual(s.fillers, 1)
        XCTAssertEqual(s.longestPause, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s.pace, 120)   // 5 words in 2.5 s of speech
    }

    func testOccurrencesOfPhraseSkipPauses() {
        let tokens = [w("как", 0), Token(kind: .pause, start: 0.5, end: 1), w("бы", 1), w("да", 1.5)]
        XCTAssertEqual(SpeechStats.occurrences(of: "как бы", in: tokens), [0, 2])
    }
}
