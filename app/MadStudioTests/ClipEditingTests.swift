import XCTest
@testable import MadStudio

/// Moving, trimming, cutting voice clips on the timeline; the text must stay in step.
@MainActor
final class ClipEditingTests: XCTestCase {
    private var project: Project!

    // "раз два" [pause 2 s] "три четыре" [pause 1 s] "пять"
    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tokens = [
            Token(kind: .word, start: 0, end: 1, text: "раз", speaker: 0),
            Token(kind: .word, start: 1, end: 2, text: "два", speaker: 0),
            Token(kind: .pause, start: 2, end: 4, speaker: 0),
            Token(kind: .word, start: 4, end: 5, text: "три", speaker: 0),
            Token(kind: .word, start: 5, end: 6, text: "четыре", speaker: 0),
            Token(kind: .pause, start: 6, end: 7, speaker: 0),
            Token(kind: .word, start: 7, end: 8, text: "пять", speaker: 0),
        ]
        let transcript = Transcript(version: 2, source: "", duration: 8, language: "ru", model: "", tokens: tokens)
        project = Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
    }

    private var voiceClips: [Lane.Clip] { project.lanes[0].clips }

    private func wordStart(_ text: String) -> Double? {
        Subtitles.words(tokens: project.tokens, states: project.states, segments: project.segments,
                        replacements: project.replacements).first { $0.text == text }?.start
    }

    func testMovingRightLengthensThePauseThenAddsSilence() {
        project.setState([2], to: .shorten)                    // the 2 s pause is kept as 0.4 s
        XCTAssertEqual(wordStart("три")!, 2.4, accuracy: 1e-6)
        project.moveClip(3...4, by: 1.0)                       // the room's own pause first
        XCTAssertEqual(wordStart("три")!, 3.4, accuracy: 1e-6)
        XCTAssertEqual(project.editedDuration, 8 - 1.6 + 1.0, accuracy: 1e-6)
        project.moveClip(3...4, by: 1.5)                       // pause is full (2 s): +0.9 s of silence
        XCTAssertEqual(wordStart("три")!, 4.9, accuracy: 1e-6)
        XCTAssertEqual(project.insertedSilence(before: 3...4), 0.9, accuracy: 1e-6)
        XCTAssertTrue(project.segments.contains { if case .silence = $0 { return true } else { return false } })
        // everything after moved too; the text is untouched
        XCTAssertEqual(wordStart("пять")!, 7.9, accuracy: 1e-6)
        XCTAssertEqual(project.states.filter { $0 == .delete }.count, 0)
    }

    func testAClipMovesWholeWithTheQuietAtItsStart() {
        project.split(before: 2)                               // clip 2: [pause 2 s] "три четыре" …
        project.moveClip(2...6, by: 1.0)
        XCTAssertEqual(wordStart("три")!, 5.0, accuracy: 1e-6)
        XCTAssertEqual(project.insertedSilence(before: 2...6), 1.0, accuracy: 1e-6)
        // the silence stands before the pause, so the clip keeps its own quiet start
        XCTAssertEqual(project.lanes[0].clips.map(\.at), [0, 3])
    }

    func testMovingLeftShortensThePauseButNotPastTheWord() {
        project.moveClip(3...4, by: -1.5)
        XCTAssertEqual(wordStart("три")!, 2.5, accuracy: 1e-6)
        project.moveClip(3...4, by: -5)                        // only the pause can go
        XCTAssertEqual(wordStart("три")!, 2.0, accuracy: 1e-6)
        XCTAssertEqual(wordStart("два")!, 1.0, accuracy: 1e-6)
        project.undo()
        XCTAssertEqual(wordStart("три")!, 2.5, accuracy: 1e-6)
    }

    func testTrimmingRemovesAndBringsBackWholeWords() {
        project.trimClip(0...6, edge: .end, by: -1.6)           // "пять" and half the pause before it
        XCTAssertEqual(project.states[6], .delete)
        XCTAssertEqual(project.states[5], .delete)
        XCTAssertEqual(project.states[4], .keep)
        project.trimClip(0...4, edge: .end, by: 2.0)           // drag out again: they come back
        XCTAssertEqual(project.states[5], .keep)
        XCTAssertEqual(project.states[6], .keep)
        project.trimClip(0...6, edge: .start, by: 0.7)         // the first word goes
        XCTAssertEqual(project.states[0], .delete)
        XCTAssertEqual(project.states[1], .keep)
    }

    func testAPieceOfVoiceBecomesItsOwnSoundWithoutMovingAnything() {
        let before = wordStart("пять")!
        let clip = UserClip(file: "/a.wav", name: "смех", at: 4, inPoint: 4, length: 2, fileDuration: 8)
        project.extract(3...4, as: clip, toMusic: false)
        XCTAssertEqual(project.states[3], .delete)
        XCTAssertEqual(project.states[4], .delete)
        XCTAssertEqual(project.mix.effects.count, 1)
        XCTAssertEqual(wordStart("пять")!, before, accuracy: 1e-6)       // silence keeps the place
        XCTAssertEqual(project.editedDuration, 8, accuracy: 1e-6)
        project.undo()
        XCTAssertEqual(project.mix.effects.count, 0)
        XCTAssertEqual(project.states[3], .keep)
    }

    func testAnAIPieceCrossfadesWithTheRealVoiceAroundIt() {
        project.addReplacement(Replacement(first: 3, last: 4, text: "три пять", file: "voice/x.wav", duration: 1.5,
                                           lead: 0.06, tail: 0.06))
        let clips = voiceClips
        guard let ai = clips.first(where: \.generated) else { return XCTFail("no AI clip") }
        // the AI piece starts 0.06 s early and ends 0.06 s late, fading in and out
        XCTAssertEqual(ai.at, 4 - 0.06, accuracy: 1e-6)
        XCTAssertEqual(ai.length, 1.5 + 0.12, accuracy: 1e-6)
        XCTAssertEqual(ai.fadeIn, 0.06, accuracy: 1e-6)
        // the real voice fades out under its start and back in under its end
        let before = clips.first { !$0.generated && abs($0.end - 4) < 0.001 }
        let after = clips.first { !$0.generated && abs($0.at - 5.5) < 0.001 }
        XCTAssertEqual(before?.fadeOut ?? 0, 0.06, accuracy: 1e-6)
        XCTAssertEqual(after?.fadeIn ?? 0, 0.06, accuracy: 1e-6)
        // the words after it keep their places
        XCTAssertEqual(project.editedDuration, 8 - 2 + 1.5, accuracy: 1e-6)
    }

    func testRazorAndClipVolume() {
        XCTAssertEqual(voiceClips.count, 1)
        project.split(before: 3)
        XCTAssertEqual(voiceClips.map(\.tokens), [0...2, 3...6])
        project.setGain(3...6, db: -6)
        XCTAssertEqual(voiceClips.map(\.gainDB), [0, -6])
        // the sound itself is unchanged: same length, same words
        XCTAssertEqual(project.editedDuration, 8, accuracy: 1e-6)
        XCTAssertEqual(wordStart("три")!, 4, accuracy: 1e-6)
    }

    func testInsertedSilenceKeepsHighlightOnTheNextWord() {
        project.moveClip(3...4, by: 3)                          // the pause is already full: 3 s of silence
        let segments = project.segments
        // during the inserted silence the text shows the word that comes next
        XCTAssertEqual(Timeline.originalTime(at: 5, segments: segments)!, 4, accuracy: 1e-6)  // silence is 4…7 s
        XCTAssertEqual(Timeline.editedTime(of: 4.5, segments: segments)!, 7.5, accuracy: 1e-6)
        project.removeSilence(before: 3...4)
        XCTAssertEqual(project.editedDuration, 8, accuracy: 1e-6)
    }
}
