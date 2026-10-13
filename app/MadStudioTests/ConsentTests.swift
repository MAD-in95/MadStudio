import XCTest
@testable import MadStudio

final class ConsentTests: XCTestCase {
    func testVoiceMatchNeedsTheSamePerson() {
        let me = VoiceProfile(name: "Я", prints: [[1, 0, 0], [0.9, 0.1, 0]], phrase: "")
        // measured: one person 0.76–0.87, different people 0.15–0.35
        XCTAssertEqual(VoiceLibrary.match([0.8, 0.2, 0.1], in: [me])?.voice.name, "Я")
        XCTAssertNil(VoiceLibrary.match([0.3, 0.9, 0.3], in: [me]))
        XCTAssertEqual(VoiceLibrary.cosine([1, 0], [0, 1]), 0, accuracy: 1e-9)
    }

    func testRecognisedVoicesLearnNewPrintsButKeepTheConfirmation() {
        func axis(_ k: Int) -> [Double] { (0..<16).map { $0 == k ? 1 : 0 } }
        let reading = axis(0), recording = axis(1)
        var voice = VoiceProfile(name: "Я", prints: [reading, recording], phrase: "")
        voice = VoiceLibrary.learning(axis(0), into: voice)        // nothing new
        XCTAssertEqual(voice.prints.count, 2)
        for k in 2..<14 { voice = VoiceLibrary.learning(axis(k), into: voice) }
        XCTAssertEqual(voice.prints.count, VoiceLibrary.maxPrints)
        XCTAssertEqual(voice.prints[0], reading)
        XCTAssertEqual(voice.prints[1], recording)
        XCTAssertEqual(voice.prints.last, axis(13))
    }

    func testPhraseHasThreeDifferentRandomWords() {
        let phrase = ConsentPhrase.make()
        XCTAssertTrue(phrase.hasPrefix("Я разрешаю этой программе говорить моим голосом."))
        let picked = ConsentPhrase.words.filter { phrase.contains($0) }
        XCTAssertGreaterThanOrEqual(picked.count, 3)
        XCTAssertNotEqual(ConsentPhrase.make(), ConsentPhrase.make())  // 40·39·38 variants
    }

    func testEngineAnswerExplainsWhatWentWrong() throws {
        let json = #"{"ok": false, "reason": "voice", "heard": "текст", "text_match": 1.0, "similarity": 0.15}"#
        let check = try JSONDecoder().decode(VoiceCheck.self, from: Data(json.utf8))
        XCTAssertFalse(check.ok)
        XCTAssertTrue(check.problem?.contains("сам человек") ?? false)
    }
}

@MainActor
final class ProjectConsentTests: XCTestCase {
    func testEveryVoiceNeedsItsOwnConsent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tokens = [Token(kind: .word, start: 0, end: 1, text: "Привет", speaker: 0),
                      Token(kind: .word, start: 1, end: 2, text: "Здравствуй", speaker: 1)]
        let transcript = Transcript(version: 2, source: "", duration: 2, language: "ru", model: "", tokens: tokens)
        let project = Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
        XCTAssertEqual(project.speakers(in: 0...1), [0, 1])
        XCTAssertFalse(project.mayUseVoice(of: 1))
        project.setConsent(.guest, for: 1)
        XCTAssertTrue(project.mayUseVoice(of: 1))
        XCTAssertFalse(project.mayUseVoice(of: 0))
        // a voice that is not (or no longer) in the list of confirmed voices does not count
        project.setConsent(.confirmed(UUID()), for: 0)
        XCTAssertFalse(project.mayUseVoice(of: 0))
        // saved with the edits
        let reopened = Project(sourceURL: URL(fileURLWithPath: "/a.wav"), transcript: transcript, folder: folder)
        XCTAssertEqual(reopened.consents[1], .guest)
    }
}

final class MicSettingsTests: XCTestCase {
    func testPresetsBuildAProcessingChain() {
        XCTAssertEqual(MicSettings.preset(.asIs).chain, "")
        let podcast = MicSettings.preset(.podcast).chain
        XCTAssertTrue(podcast.hasPrefix("highpass=f=80"))
        XCTAssertTrue(podcast.contains("dynaudnorm") && podcast.contains("acompressor") && podcast.hasSuffix("level=false"))
        XCTAssertFalse(MicSettings.preset(.studio).chain.contains("dynaudnorm"))   // studio stays natural
    }

    func testCalibrationFitsTheCompressorToTheVoice() {
        var s = MicSettings.preset(.podcast)
        s.calibrate(quiet: -40, loud: -14)            // a voice that is much quieter at times
        XCTAssertEqual(s.threshold, -32, accuracy: 0.5)
        XCTAssertGreaterThan(s.makeup, 5)
        XCTAssertGreaterThanOrEqual(s.leveler, 0.5)
    }
}
