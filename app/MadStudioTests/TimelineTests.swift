import XCTest
@testable import MadStudio

final class TimelineTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/rec.wav")

    private func w(_ text: String, _ start: Double, _ end: Double, speaker: Int) -> Token {
        Token(kind: .word, start: start, end: end, text: text, speaker: speaker)
    }

    func testSpeakerLanesFollowCuts() {
        let tokens = [w("Привет", 0, 1, speaker: 0), Token(kind: .pause, start: 1, end: 3, speaker: 0),
                      w("Здравствуй", 3, 4, speaker: 1), w("да", 4, 5, speaker: 0)]
        let states: [TokenState] = [.keep, .delete, .keep, .keep]
        let segments = Editing.timeline(tokens: tokens, states: states, keepPause: 0.4, replacements: [], folder: nil)
        let lanes = Timeline.lanes(tokens: tokens, segments: segments, source: source, stems: nil,
                                   mix: Mix(), speakerCount: 2)
        XCTAssertEqual(lanes.map(\.id), ["speaker:0", "speaker:1", "music", "effects"])
        // speaker 0: "Привет" at 0, "да" right after "Здравствуй" (the pause is cut)
        XCTAssertEqual(lanes[0].clips.map(\.at), [0, 2])
        XCTAssertEqual(lanes[0].clips.map(\.src), [0, 4])
        XCTAssertEqual(lanes[1].clips.map(\.at), [1])
        XCTAssertEqual(Timeline.duration(lanes), 3, accuracy: 1e-9)
    }

    func testTimeMappingBothWays() {
        let segments: [Segment] = [.original(TimeRange(start: 0, end: 1)), .original(TimeRange(start: 3, end: 5))]
        XCTAssertEqual(Timeline.originalTime(at: 1.5, segments: segments)!, 3.5, accuracy: 1e-9)
        XCTAssertEqual(Timeline.editedTime(of: 3.5, segments: segments)!, 1.5, accuracy: 1e-9)
        XCTAssertNil(Timeline.editedTime(of: 2, segments: segments))
    }

    func testMuteSoloAndDucking() {
        var mix = Mix()
        mix.tracks["speaker:1"] = TrackSettings(muted: true)
        let keys = ["speaker:0", "speaker:1", "music"]
        XCTAssertTrue(Timeline.audible("speaker:0", in: mix, keys: keys))
        XCTAssertFalse(Timeline.audible("speaker:1", in: mix, keys: keys))
        mix.tracks["music"] = TrackSettings(solo: true)
        XCTAssertFalse(Timeline.audible("speaker:0", in: mix, keys: keys))

        let music = UserClip(file: "/m.mp3", name: "m", at: 0, length: 10, fileDuration: 60)
        let lanes = [Lane(kind: .music, clips: [Lane.Clip(file: URL(fileURLWithPath: music.file), src: 0, length: 10, at: 0)])]
        let plan = Timeline.plan(lanes: lanes, mix: Mix(), speech: [[1, 2]], sampleRate: 48000, channels: 2, loudness: nil)
        let track = (plan["tracks"] as! [[String: Any]])[0]
        XCTAssertNotNil(track["duck"])
    }
}

@MainActor
final class SpeakerCorrectionTests: XCTestCase {
    func testAssigningSpeakerByHandIsUndoable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tokens = [Token(kind: .word, start: 0, end: 1, text: "Мозаикой", speaker: 1),
                      Token(kind: .word, start: 1, end: 2, text: "пол", speaker: 0)]
        let transcript = Transcript(version: 2, source: "", duration: 2, language: "ru", model: "", tokens: tokens)
        let project = Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
        project.assignSpeaker([0], to: 0)
        XCTAssertEqual(project.tokens[0].speaker, 0)
        project.undo()
        XCTAssertEqual(project.tokens[0].speaker, 1)
        // the correction is saved with the edits
        project.redo()
        let reopened = Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
        XCTAssertEqual(reopened.tokens[0].speaker, 0)
    }
}


final class MixCompatibilityTests: XCTestCase {
    func testEditsSavedBeforeVoiceProcessingStillLoad() throws {
        let old = #"{"tracks": {"music": {"gainDB": -6, "muted": false, "solo": false}}, "music": [], "effects": [], "duck": true, "duckDepth": 12}"#
        let mix = try JSONDecoder().decode(Mix.self, from: Data(old.utf8))
        XCTAssertEqual(mix.settings("music").gainDB, -6)
        XCTAssertFalse(mix.voice.isOn)
    }

    func testProcessedVoiceReplacesTheVoiceOnSpeakerTracks() {
        let tokens = [Token(kind: .word, start: 0, end: 1, text: "да", speaker: 0)]
        let segments: [Segment] = [.original(TimeRange(start: 0, end: 1))]
        let processed = URL(fileURLWithPath: "/p/voicefx/voice.flac")
        let lanes = Timeline.lanes(tokens: tokens, segments: segments, source: URL(fileURLWithPath: "/rec.wav"),
                                   stems: nil, mix: Mix(), speakerCount: 1, processedVoice: processed)
        XCTAssertEqual(lanes[0].clips[0].file, processed)
    }
}
