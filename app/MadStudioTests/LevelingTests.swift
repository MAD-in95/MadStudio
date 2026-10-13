import XCTest
@testable import MadStudio

final class LevelingTests: XCTestCase {
    /// two speakers talking in turns for 20 s each; the second one 8 dB quieter
    private func recording() -> (tokens: [Token], peaks: [Float]) {
        var tokens: [Token] = [], peaks: [Float] = []
        for turn in 0..<4 {
            let speaker = turn % 2, db = speaker == 0 ? -18.0 : -26.0
            for w in 0..<20 {
                let start = Double(turn * 20 + w)
                tokens.append(Token(kind: .word, start: start, end: start + 0.8, text: "слово", speaker: speaker))
                // inside a word: loud, then a fading end; between words: quiet
                peaks += (0..<16).map { Float(((Double($0) < 12 ? db : db - 15) + 50) / 50) }
                peaks += (0..<4).map { _ in Float((-48.0 + 50) / 50) }
            }
        }
        return (tokens, peaks)
    }

    func testMeasuresSpeechNotPauses() {
        let r = recording()
        let levels = Leveling.levels(tokens: r.tokens, peaks: r.peaks)
        XCTAssertEqual(levels[0]!, -18, accuracy: 1)
        XCTAssertEqual(levels[1]!, -26, accuracy: 1)
    }

    func testBringsBothToTheMiddle() {
        let r = recording()
        let gains = Leveling.gains(for: Leveling.levels(tokens: r.tokens, peaks: r.peaks))
        XCTAssertEqual(gains[0]!, -4, accuracy: 0.5)
        XCTAssertEqual(gains[1]!, 4, accuracy: 0.5)
    }

    func testTooLittleSpeechOrOneSpeakerChangesNothing() {
        XCTAssertTrue(Leveling.gains(for: [0: -20]).isEmpty)
        let short = [Token(kind: .word, start: 0, end: 1, text: "да", speaker: 1)]
        XCTAssertNil(Leveling.levels(tokens: short, peaks: Array(repeating: 0.6, count: 40))[1])
    }
}
