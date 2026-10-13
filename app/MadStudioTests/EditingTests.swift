import XCTest
@testable import MadStudio

final class EditingTests: XCTestCase {
    private let tokens: [Token] = [
        Token(kind: .word, start: 0, end: 1, text: "Привет"),
        Token(kind: .pause, start: 1, end: 3),
        Token(kind: .breath, start: 3, end: 3.5),
        Token(kind: .word, start: 3.5, end: 4, text: "ээ", parasite: true),
        Token(kind: .word, start: 4, end: 5, text: "мир"),
        Token(kind: .click, start: 5, end: 5.05),
    ]

    func testNothingDeletedKeepsWholeRecording() {
        let states = Array(repeating: TokenState.keep, count: tokens.count)
        XCTAssertEqual(Editing.keepRanges(tokens: tokens, states: states, keepPause: 0.4),
                       [TimeRange(start: 0, end: 5.05)])
    }

    func testAutoCleanShortensPausesAndRemovesNoise() {
        let start = Array(repeating: TokenState.keep, count: tokens.count)
        let states = Editing.autoClean(tokens: tokens, states: start, options: CleanOptions())
        XCTAssertEqual(states, [.keep, .shorten, .delete, .delete, .keep, .keep])

        let ranges = Editing.keepRanges(tokens: tokens, states: states, keepPause: 0.4)
        XCTAssertEqual(ranges, [TimeRange(start: 0, end: 1.2), TimeRange(start: 2.8, end: 3),
                                TimeRange(start: 4, end: 5.05)])
        XCTAssertEqual(Editing.duration(of: ranges), 1.2 + 0.2 + 1.05, accuracy: 1e-9)
    }

    func testAutoCleanKeepsManualWordDeletions() {
        var start = Array(repeating: TokenState.keep, count: tokens.count)
        start[4] = .delete
        let states = Editing.autoClean(tokens: tokens, states: start, options: CleanOptions())
        XCTAssertEqual(states[4], .delete)
    }

    func testAutoCleanNeverRemovesUntranscribedSpeech() {
        let speech = [Token(kind: .speech, start: 0, end: 1, text: "давай")]
        XCTAssertEqual(Editing.autoClean(tokens: speech, states: [.keep], options: CleanOptions()), [.keep])
    }

    func testUnknownKindFromNewerEngineIsReadAsSpeech() throws {
        let json = #"{"kind": "laugh", "start": 0, "end": 1}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Token.self, from: json).kind, .speech)
    }

    func testTakesAreRemovedOnlyWhenAsked() {
        let tokens = [Token(kind: .word, start: 0, end: 1, text: "я", take: 1),
                      Token(kind: .word, start: 1, end: 2, text: "я")]
        let keep: [TokenState] = [.keep, .keep]
        XCTAssertEqual(Editing.autoClean(tokens: tokens, states: keep, options: CleanOptions()), [.keep, .keep])
        var options = CleanOptions()
        options.takes = true
        XCTAssertEqual(Editing.autoClean(tokens: tokens, states: keep, options: options), [.delete, .keep])
    }

    func testOldSavedOptionsStillLoad() throws {
        let json = #"{"pauses": false, "maxPause": 1, "keepPause": 0.4, "breaths": true, "fillers": true, "clicks": false}"#
        let options = try JSONDecoder().decode(CleanOptions.self, from: Data(json.utf8))
        XCTAssertFalse(options.pauses)
        XCTAssertFalse(options.takes)
    }

    func testReplacementTakesThePlaceOfItsWords() {
        let words = (0..<4).map { Token(kind: .word, start: Double($0), end: Double($0 + 1), text: "w\($0)") }
        let states = Array(repeating: TokenState.keep, count: 4)
        let r = Replacement(first: 1, last: 2, text: "новое", file: "voice/a.wav", duration: 1.5)
        let folder = URL(fileURLWithPath: "/p")
        let segments = Editing.timeline(tokens: words, states: states, keepPause: 0.4, replacements: [r], folder: folder)
        XCTAssertEqual(segments, [
            .original(TimeRange(start: 0, end: 1)),
            .generated(file: URL(fileURLWithPath: "/p/voice/a.wav"), duration: 1.5, at: 1),
            .original(TimeRange(start: 3, end: 4)),
        ])
        XCTAssertEqual(Editing.duration(of: segments), 3.5, accuracy: 1e-9)
    }

    func testIsKept() {
        let ranges = [TimeRange(start: 0, end: 1), TimeRange(start: 2, end: 3)]
        XCTAssertTrue(Editing.isKept(0.5, in: ranges))
        XCTAssertFalse(Editing.isKept(1.5, in: ranges))
        XCTAssertTrue(Editing.isKept(2, in: ranges))
        XCTAssertFalse(Editing.isKept(3, in: ranges))
    }

    func testTokenAtTime() {
        XCTAssertEqual(Editing.tokenIndex(at: 0.5, in: tokens), 0)
        XCTAssertEqual(Editing.tokenIndex(at: 3.2, in: tokens), 2)
        XCTAssertEqual(Editing.tokenIndex(at: 99, in: tokens), 5)
    }
}
