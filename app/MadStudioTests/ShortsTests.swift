import XCTest
@testable import MadStudio

final class ShortsTests: XCTestCase {
    // original 0–10 kept, 10–20 cut, 20–40 kept
    private let segments: [Segment] = [.original(TimeRange(start: 0, end: 10)), .original(TimeRange(start: 20, end: 40))]

    func testMomentsAreKeptInOriginalTimeAndFollowLaterCuts() throws {
        let answer = #"{"moments": [{"start": 12, "end": 30, "title": "Т", "why": "П", "score": 8, "text": "…"}]}"#
        let moments = try Shorts.moments(fromEngine: Data(answer.utf8), segments: segments)
        XCTAssertEqual(moments.count, 1)
        XCTAssertEqual(moments[0].start, 22, accuracy: 1e-6)    // edited 12 s = original 22 s
        XCTAssertEqual(moments[0].end, 40, accuracy: 0.01)
        XCTAssertEqual(moments[0].grade, "сильный")

        // nothing changed: the same place
        let range = try XCTUnwrap(Shorts.edited(moments[0], segments: segments))
        XCTAssertEqual(range.lowerBound, 12, accuracy: 1e-6)
        // later the first 10 s are cut: the moment moves with the text
        let later: [Segment] = [.original(TimeRange(start: 20, end: 40))]
        let moved = try XCTUnwrap(Shorts.edited(moments[0], segments: later))
        XCTAssertEqual(moved.lowerBound, 2, accuracy: 1e-6)
    }

    func testCutMomentStartContinuesWhereTheRecordingDoes() {
        XCTAssertEqual(Timeline.editedTimeOrNext(of: 15, segments: segments), 10, accuracy: 1e-9)
        XCTAssertEqual(Timeline.editedTimeOrNext(of: 50, segments: segments), 30, accuracy: 1e-9)
        let gone = ShortMoment(start: 12, end: 18, title: "", why: "", score: 7, text: "")
        XCTAssertNil(Shorts.edited(gone, segments: segments))
    }

    func testTrimKeepsOnlyThePieceFromZeroWithSoftMusicEdges() {
        let file = URL(fileURLWithPath: "/a.wav")
        let lanes = [
            Lane(kind: .speaker(0), clips: [Lane.Clip(file: file, src: 0, length: 10, at: 0),
                                            Lane.Clip(file: file, src: 20, length: 20, at: 10)]),
            Lane(kind: .music, clips: [Lane.Clip(file: file, src: 0, length: 30, at: 0, fadeIn: 1, fadeOut: 2)]),
        ]
        let piece = Timeline.trim(lanes, to: 5...25)
        XCTAssertEqual(piece[0].clips.map(\.at), [0, 5])
        XCTAssertEqual(piece[0].clips.map(\.src), [5, 20])
        XCTAssertEqual(piece[0].clips.map(\.length), [5, 15])
        XCTAssertEqual(piece[0].clips[0].fadeIn, 0)            // voices: no fades added
        XCTAssertEqual(piece[1].clips[0].fadeIn, 0.5)          // music cut in the middle fades in and out
        XCTAssertEqual(piece[1].clips[0].fadeOut, 1)
        XCTAssertEqual(Timeline.duration(piece), 20, accuracy: 1e-9)
        XCTAssertEqual(Timeline.trim(speech: [[1, 6], [24, 30]], to: 5...25), [[0, 1], [19, 20]])
    }

    func testSubtitlesOfAPieceStartAtZero() {
        let words = [Subtitles.Word(text: "до", start: 1, end: 2), Subtitles.Word(text: "Привет", start: 10, end: 10.5),
                     Subtitles.Word(text: "всем.", start: 10.5, end: 11)]
        let cues = Shorts.cues(words, in: 9.8...20)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Привет всем.")
        XCTAssertEqual(cues[0].start, 0.2, accuracy: 1e-9)
    }

    func testFileNamesHaveNoForbiddenCharacters() {
        XCTAssertEqual(Shorts.fileName("Интервью", number: 2, title: "Почему? 16/20: \"да\""),
                       "Интервью — Shorts 2 — Почему  16 20   да")
    }
}
