import XCTest
@testable import MadStudio

/// «Исправить текст»: the spelling changes, the sound and the timing don't.
@MainActor
final class TextFixTests: XCTestCase {
    private var project: Project!
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = makeProject()
    }

    private func makeProject() -> Project {
        let tokens = [
            Token(kind: .word, start: 0, end: 1, text: "Привет,", speaker: 0),
            Token(kind: .word, start: 1, end: 2, text: "Никит.", speaker: 0),
            Token(kind: .pause, start: 2, end: 3, speaker: 0),
            Token(kind: .word, start: 3, end: 4, text: "как", speaker: 0),
            Token(kind: .word, start: 4, end: 5, text: "дела", speaker: 0),
        ]
        let transcript = Transcript(version: 2, source: "", duration: 5, language: "ru", model: "", tokens: tokens)
        return Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
    }

    private var subtitleWords: [Subtitles.Word] {
        Subtitles.words(tokens: project.tokens, states: project.states, segments: project.segments,
                        replacements: project.replacements)
    }

    func testOneWordKeepsItsTimingAndTheSound() {
        let before = project.editedDuration
        project.correctText(1, 1, to: "Никита.")
        XCTAssertEqual(project.shownText(0, 4), "Привет, Никита. как дела")
        XCTAssertEqual(subtitleWords[1].text, "Никита.")
        XCTAssertEqual(subtitleWords[1].start, 1, accuracy: 1e-9)
        XCTAssertEqual(project.editedDuration, before)
        project.undo()
        XCTAssertEqual(project.shownText(1, 1), "Никит.")
    }

    func testFewerAndMoreWords() {
        project.correctText(3, 4, to: "Какдела")                 // two places, one word: the second is emptied
        XCTAssertEqual(subtitleWords.map(\.text), ["Привет,", "Никит.", "Какдела"])
        project.correctText(0, 1, to: "Привет, дорогой Никита.")   // three words, two places: extras join the last
        XCTAssertEqual(project.shownText(0, 1), "Привет, дорогой Никита.")
    }

    func testKeptAfterReopening() {
        project.correctText(1, 1, to: "Никита.")
        XCTAssertEqual(makeProject().shownText(1, 1), "Никита.")
        XCTAssertEqual(TranscriptSearch.matches("никита", in: makeProject().tokens), [1...1])
    }

    /// Opening a project must not write its edits back half-read (this lost names and volumes).
    func testOpeningTwiceKeepsEverything() {
        project.renameSpeaker(0, to: "Гость")
        project.correctText(1, 1, to: "Никита.")
        project.changeMix { $0.tracks["speaker-0", default: TrackSettings()].gainDB = -6 }
        _ = makeProject()
        let again = makeProject()
        XCTAssertEqual(again.speakerName(0), "Гость")
        XCTAssertEqual(again.shownText(1, 1), "Никита.")
        XCTAssertEqual(again.mix, project.mix)
    }
}
