import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Steps shared by opening one recording and by batch processing.
@MainActor
enum Pipeline {
    /// A file macOS can play as audio directly (not a video, not an exotic format).
    static func isPlayableAudio(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) { return false }
        return (try? AVAudioFile(forReading: url)) != nil
    }

    /// The sound of a file: the file itself, or its sound taken out once (videos, exotic formats).
    static func audio(for url: URL) async throws -> URL {
        if isPlayableAudio(url) { return url }
        let folder = AppPaths.media.appendingPathComponent(Project.key(for: url))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { isPlayableAudio($0) }) {
            return existing
        }
        let base = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
        let data = try await Engine.run(["extract-audio", url.path, base.path])
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let path = result?["path"] as? String else { throw EngineError.failed(String(localized: "Не удалось достать звук")) }
        return URL(fileURLWithPath: path)
    }

    /// The project of a recording: opened if transcribed before (upgraded when old),
    /// otherwise transcribed now.
    static func project(for audio: URL, model: String,
                        onEvent: @escaping @MainActor (EngineEvent) -> Void = { _ in }) async throws -> Project {
        if let project = Project.load(source: audio) {
            guard project.transcript.version < currentTranscriptVersion else { return project }
            _ = try? await Engine.run(["reanalyze", Project.transcriptURL(in: project.folder).path])
            return Project.load(source: audio) ?? project
        }
        let output = Project.transcriptURL(in: Project.folder(for: audio))
        _ = try await Engine.run(["transcribe", audio.path, output.path, "--model", model], onEvent: onEvent)
        guard let project = Project.load(source: audio) else {
            throw EngineError.failed(String(localized: "Не удалось прочитать расшифровку"))
        }
        return project
    }

    /// Turns voice processing on/off: makes the processed voice once (fast), then the
    /// speaker tracks play it. The original recording is never changed.
    static func setVoiceFX(_ fx: VoiceFX, for project: Project,
                           onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async throws {
        if fx.isOn {
            let output = project.voiceFXFile(fx)
            if !FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let source = project.stems?.voice ?? project.sourceURL
                var args = ["voicefx", source.path, output.path, "--denoise", fx.denoise]
                if fx.radio { args.append("--radio") }
                _ = try await Engine.run(args) { event in
                    if event.stage == "voicefx" { onProgress(event.value ?? 0) }
                }
            }
        }
        project.changeMix { $0.voice = fx }
    }

    /// Saves the edited recording with all tracks mixed; `loudness` is a preset id
    /// ("youtube", …) or nil. `include` limits which tracks go in (e.g. voices only);
    /// `range` saves only that stretch of the edited recording (e.g. a moment for Shorts).
    static func export(_ project: Project, to output: URL, loudness: String?,
                       range: ClosedRange<Double>? = nil,
                       include: @escaping (Lane.Kind) -> Bool = { _ in true },
                       onProgress: @escaping @MainActor (Double) -> Void = { _ in }) async throws {
        let format = (try? AVAudioFile(forReading: project.sourceURL))?.processingFormat
        var lanes = project.lanes
        var speech = project.speech
        if let range {
            lanes = Timeline.trim(lanes, to: range)
            speech = Timeline.trim(speech: speech, to: range)
        }
        let stereo = project.stems != nil || !project.mix.music.isEmpty || !project.mix.effects.isEmpty
        let plan = Timeline.plan(lanes: lanes, mix: project.mix, speech: speech,
                                 sampleRate: Int(format?.sampleRate ?? 48000),
                                 channels: stereo ? 2 : Int(format?.channelCount ?? 1),
                                 loudness: loudness, include: include)
        let planURL = project.folder.appendingPathComponent(range == nil ? "mix-plan.json" : "mix-plan-piece.json")
        try JSONSerialization.data(withJSONObject: plan).write(to: planURL)
        _ = try await Engine.run(["mixdown", planURL.path, output.path]) { event in
            if event.stage == "export" { onProgress(event.value ?? 0) }
        }
    }
}

extension Project {
    /// Subtitles of the edited recording.
    var subtitleCues: [Subtitles.Cue] {
        Subtitles.cues(Subtitles.words(tokens: tokens, states: states, segments: segments, replacements: replacements))
    }
}
