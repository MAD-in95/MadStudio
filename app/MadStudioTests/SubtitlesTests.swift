import XCTest
@testable import MadStudio

final class SubtitlesTests: XCTestCase {
    private func word(_ text: String, _ start: Double, _ end: Double, speaker: Int? = nil) -> Token {
        Token(kind: .word, start: start, end: end, text: text, speaker: speaker)
    }

    func testTimesFollowTheCuts() {
        let tokens = [word("Привет,", 0, 1), Token(kind: .pause, start: 1, end: 3), word("мир.", 3, 4)]
        let states: [TokenState] = [.keep, .delete, .keep]
        let segments = Editing.timeline(tokens: tokens, states: states, keepPause: 0.4, replacements: [], folder: nil)
        let words = Subtitles.words(tokens: tokens, states: states, segments: segments, replacements: [])
        XCTAssertEqual(words.map(\.text), ["Привет,", "мир."])
        // the pause is gone: "мир." starts right after "Привет," minus the export crossfade
        XCTAssertEqual(words[1].start, 1 - Subtitles.joinOverlap, accuracy: 1e-9)
    }

    func testReVoicedWordsAppearInSubtitles() {
        let tokens = [word("показано", 0, 1), word("30", 1, 1.3), word("секунд.", 1.3, 2)]
        let r = Replacement(first: 1, last: 1, text: "сорок пять", file: "v.wav", duration: 0.8)
        let segments = Editing.timeline(tokens: tokens, states: [.keep, .keep, .keep], keepPause: 0.4,
                                        replacements: [r], folder: URL(fileURLWithPath: "/p"))
        let words = Subtitles.words(tokens: tokens, states: [.keep, .keep, .keep], segments: segments, replacements: [r])
        XCTAssertEqual(words.map(\.text), ["показано", "сорок пять", "секунд."])
    }

    func testCuesBreakAtSpeakerChangeAndLength() {
        let words = [
            Subtitles.Word(text: "Как", start: 0, end: 0.3, speaker: 0),
            Subtitles.Word(text: "дела?", start: 0.3, end: 0.8, speaker: 0),
            Subtitles.Word(text: "Отлично.", start: 1.0, end: 1.6, speaker: 1),
        ]
        let cues = Subtitles.cues(words)
        XCTAssertEqual(cues.map(\.text), ["Как дела?", "Отлично."])
        let long = (0..<20).map { Subtitles.Word(text: "слово\($0)", start: Double($0) * 0.3, end: Double($0) * 0.3 + 0.25) }
        XCTAssertTrue(Subtitles.cues(long).allSatisfy { $0.text.count <= Subtitles.maxChars })
    }

    func testSrtFormat() {
        let srt = Subtitles.srt([Subtitles.Cue(start: 3725.5, end: 3727, text: "Привет")])
        XCTAssertEqual(srt, "1\n01:02:05,500 --> 01:02:07,000\nПривет\n")
    }
}

final class TextDocumentTests: XCTestCase {
    func testTextIsExportedInParagraphsWithNamesAndTimecodes() {
        let words = [Subtitles.Word(text: "Привет", start: 0, end: 0.5, speaker: 0),
                     Subtitles.Word(text: "всем.", start: 0.5, end: 1, speaker: 0),
                     Subtitles.Word(text: "Здравствуй", start: 65, end: 66, speaker: 1),
                     Subtitles.Word(text: "-то", start: 66, end: 66.2, speaker: 1)]
        let plain = Subtitles.document(words, names: nil, timecodes: false)
        XCTAssertEqual(plain, "Привет всем.\n\nЗдравствуй-то\n")
        let full = Subtitles.document(words, names: ["Кукушкин", "Ведущий"], timecodes: true)
        XCTAssertEqual(full, "[0:00] Кукушкин: Привет всем.\n\n[1:05] Ведущий: Здравствуй-то\n")
    }
}
