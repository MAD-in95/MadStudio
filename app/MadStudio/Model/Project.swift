import AVFoundation
import CryptoKit
import Foundation
import Observation

/// An opened recording with its transcript and edits. The original file is never changed:
/// edits are stored separately and can always be undone.
@Observable
@MainActor
final class Project {
    let sourceURL: URL
    let transcript: Transcript
    let folder: URL
    private(set) var states: [TokenState]
    private(set) var replacements: [Replacement] = []
    /// Track volumes, music, effects, ducking.
    private(set) var mix = Mix()
    /// Names the user gave to speakers ("Спикер 1" -> "Дудь").
    private(set) var speakerNames: [Int: String] = [:]
    /// Earlier versions: one checkbox "it's my voice or I have consent" for the whole recording.
    /// Projects where it was ticked keep working; new ones confirm every voice separately.
    var voiceConsent = false { didSet { save() } }
    /// Speaker -> why the program may speak in their voice (read the phrase / guest's consent).
    private(set) var consents: [Int: VoiceConsent] = [:]
    /// Pauses, cuts and volumes set with the mouse on the timeline.
    private(set) var arrangement = Arrangement()
    private(set) var revision = 0
    /// Changes when the edited sound itself changes (cuts, re-voicing) — not track volumes.
    private(set) var contentRevision = 0
    var options: CleanOptions { didSet { save() } }
    /// Moments for Shorts the language model found (kept in their own file, not in the edits).
    var shorts: [ShortMoment] { didSet { Shorts.save(shorts, to: folder) } }

    private struct Snapshot: Equatable {
        var states: [TokenState]
        var replacements: [Replacement]
        var mix: Mix
        var speakerOverrides: [Int: Int]
        var arrangement: Arrangement
        var textFixes: [Int: String]
    }
    /// true while the saved edits are being read: nothing is written back half-loaded
    @ObservationIgnored private var loading = true
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    /// The transcript's tokens with the person's corrections (who said what) applied.
    private(set) var tokens: [Token] = []
    /// token index -> speaker, set by hand when automatic speaker detection was wrong
    private(set) var speakerOverrides: [Int: Int] = [:]
    /// word index -> corrected text (a misheard word, a name); the sound stays as it is
    private(set) var textFixes: [Int: String] = [:]
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var segments: [Segment] {
        Editing.timeline(tokens: tokens, states: states, keepPause: options.keepPause,
                         replacements: replacements, folder: folder, arrangement: arrangement)
    }
    var keepRanges: [TimeRange] {
        segments.compactMap { if case .original(let r) = $0 { return r } else { return nil } }
    }
    var editedDuration: Double { Editing.duration(of: segments) }

    var speakerCount: Int { transcript.speakers?.count ?? 0 }

    func speakerName(_ id: Int) -> String {
        speakerNames[id] ?? String(localized: "Спикер \(id + 1)")
    }

    func renameSpeaker(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        speakerNames[id] = trimmed.isEmpty ? nil : trimmed
        revision += 1
        save()
    }

    // MARK: Timeline editing (voice clips)

    private func kept(_ i: Int, in s: Snapshot) -> Double {
        Editing.keptLength(i, tokens: tokens, states: s.states, keepPause: options.keepPause, arrangement: s.arrangement)
    }

    private func isSpeech(_ i: Int) -> Bool {
        tokens[i].kind == .word || tokens[i].kind == .speech
    }

    /// Where a moved clip begins: its first token — unless that is the second half of a
    /// shortened pause (its first half ends the previous clip); then the token after it.
    func clipStart(_ clip: ClosedRange<Int>) -> Int {
        let first = clip.lowerBound
        let partial = !isSpeech(first) && states[first] != .delete
            && Editing.keptLength(first, tokens: tokens, states: states, keepPause: options.keepPause,
                                  arrangement: arrangement) < tokens[first].duration - 0.0005
        return partial && first < clip.upperBound ? first + 1 : first
    }

    /// Moves a voice clip along the timeline. The timeline is "magnetic", like in Final Cut:
    /// to the right — the pause before the clip gets longer (the room's own quiet first,
    /// then silence); to the left — the pause gets shorter, never past the previous word.
    /// Everything after the clip moves with it, so the text and the sound stay in step.
    func moveClip(_ clip: ClosedRange<Int>, by delta: Double) {
        guard abs(delta) > 0.005 else { return }
        let first = clipStart(clip)
        var before: [Int] = []   // non-speech tokens back to the previous word, nearest first
        var k = first - 1
        while k >= 0, !isSpeech(k), replacement(covering: k) == nil {
            before.append(k)
            k -= 1
        }
        record { s in
            if delta > 0 {
                var left = delta
                for p in before where tokens[p].kind == .pause && left > 0.0005 {
                    let now = kept(p, in: s), full = tokens[p].duration
                    let grow = min(full - now, left)
                    guard grow > 0.0005 else { continue }
                    if s.states[p] == .delete { s.states[p] = .keep }
                    s.arrangement.pauses[p] = now + grow
                    left -= grow
                }
                if left > 0.0005 { s.arrangement.gaps[first, default: 0] += left }
            } else {
                var left = -delta
                let gap = s.arrangement.gaps[first] ?? 0
                let used = min(gap, left)
                s.arrangement.gaps[first] = gap - used > 0.0005 ? gap - used : nil
                left -= used
                for p in before where left > 0.0005 {
                    let now = kept(p, in: s)
                    guard now > 0.0005 else { continue }
                    if tokens[p].kind == .pause && now - left > 0.02 {
                        s.arrangement.pauses[p] = now - left
                        left = 0
                    } else {
                        s.states[p] = .delete         // a breath or click goes as a whole
                        s.arrangement.pauses[p] = nil
                        left -= now
                    }
                }
            }
        }
    }

    enum ClipEdge { case start, end }

    /// Drags an edge of a voice clip: in — whole tokens go (and leave the text), out —
    /// earlier cut tokens come back. Always by whole words.
    func trimClip(_ clip: ClosedRange<Int>, edge: ClipEdge, by delta: Double) {
        guard abs(delta) > 0.01 else { return }
        let inward = (edge == .end) == (delta < 0)
        var left = abs(delta)
        record { s in
            if inward {
                var order = Array(clip)
                if edge == .end { order.reverse() }
                for i in order {
                    let now = kept(i, in: s)
                    guard now > 0.0005 else { continue }
                    guard now / 2 <= left else { break }
                    s.states[i] = .delete
                    s.arrangement.pauses[i] = nil
                    left -= now
                }
            } else {
                var i = edge == .end ? clip.upperBound + 1 : clip.lowerBound - 1
                while i >= 0, i < tokens.count, left > 0, replacement(covering: i) == nil {
                    let full = tokens[i].duration, now = kept(i, in: s)
                    if now >= full - 0.0005 { break }               // reached kept sound: the next clip
                    guard (full - now) / 2 <= left else { break }
                    s.states[i] = .keep
                    s.arrangement.pauses[i] = nil
                    left -= full - now
                    i += edge == .end ? 1 : -1
                }
            }
        }
    }

    /// Takes a piece of the voice out as its own sound (a laugh, a clap) on the music or
    /// effects track; the voice keeps a silence of the same length, so nothing moves.
    func extract(_ clip: ClosedRange<Int>, as sound: UserClip, toMusic: Bool) {
        let fileLength = (try? AVAudioFile(forReading: URL(fileURLWithPath: sound.file)))
            .map { Double($0.length) / $0.processingFormat.sampleRate } ?? sound.inPoint + sound.length
        var sound = sound
        sound.fileDuration = fileLength
        record { s in
            let kept = clip.reduce(0.0) { $0 + kept($1, in: s) }
            for i in clip {
                s.states[i] = .delete
                s.arrangement.pauses[i] = nil
            }
            if clip.upperBound + 1 < tokens.count {
                s.arrangement.gaps[clip.upperBound + 1, default: 0] += kept
            }
            if toMusic { s.mix.music.append(sound) } else { s.mix.effects.append(sound) }
        }
    }

    /// Razor: the clip is cut in two before token i.
    func split(before i: Int) {
        guard i > 0, i < tokens.count else { return }
        record { $0.arrangement.splits.insert(i) }
    }

    /// Volume of a voice clip (0 — as recorded).
    func setGain(_ clip: ClosedRange<Int>, db: Double) {
        record { s in
            s.arrangement.gains.removeAll { !($0.last < clip.lowerBound || $0.first > clip.upperBound) }
            if abs(db) > 0.05 { s.arrangement.gains.append(ClipGain(first: clip.lowerBound, last: clip.upperBound, db: db)) }
        }
    }

    /// Silence put in before a clip on the timeline, if any.
    func insertedSilence(before clip: ClosedRange<Int>) -> Double {
        arrangement.gaps[clipStart(clip)] ?? 0
    }

    func removeSilence(before clip: ClosedRange<Int>) {
        let first = clipStart(clip)
        record { $0.arrangement.gaps[first] = nil }
    }

    // MARK: Voices

    /// May the program speak in this speaker's voice?
    func mayUseVoice(of speaker: Int) -> Bool {
        switch consents[speaker] {
        case .confirmed(let id): return VoiceLibrary.contains(id) || voiceConsent
        case .guest: return true
        case nil: return voiceConsent
        }
    }

    func setConsent(_ consent: VoiceConsent?, for speaker: Int) {
        consents[speaker] = consent
        revision += 1
        save()
    }

    /// Who speaks in tokens first...last (0 for recordings without speakers).
    func speakers(in range: ClosedRange<Int>) -> [Int] {
        let ids = Set(tokens[range].filter(\.isWord).map { $0.speaker ?? 0 })
        return ids.isEmpty ? [tokens[range.lowerBound].speaker ?? 0] : ids.sorted()
    }

    /// Everyone heard in the edited recording.
    var allSpeakers: [Int] { Array(0..<max(speakerCount, 1)) }

    /// Voice prints of the speakers (cached next to the transcript; made by the engine).
    var voicePrints: [Int: [Double]] {
        get {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("prints.json")),
                  let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(raw) {
                try? data.write(to: folder.appendingPathComponent("prints.json"))
            }
        }
    }

    /// The tokens with the person's corrections, as a file for the engine (who speaks where
    /// matters for re-voicing: the voice sample must be the same person).
    func writeTokens() throws -> URL {
        let url = folder.appendingPathComponent("tokens-edited.json")
        try JSONEncoder().encode(["tokens": tokens]).write(to: url)
        return url
    }

    // MARK: Tracks

    var stems: Stems? { Stems.found(in: folder) }

    var lanes: [Lane] {
        Timeline.lanes(tokens: tokens, segments: segments, source: sourceURL, stems: stems,
                       mix: mix, speakerCount: speakerCount, processedVoice: processedVoice,
                       replacements: replacements, arrangement: arrangement)
    }

    /// Where the voice processed with these settings is (or will be) kept.
    func voiceFXFile(_ fx: VoiceFX) -> URL {
        folder.appendingPathComponent("voicefx").appendingPathComponent(fx.fileName(fromStems: stems != nil))
    }

    /// The processed voice the speaker tracks play, if processing is on and ready.
    var processedVoice: URL? {
        guard mix.voice.isOn else { return nil }
        let url = voiceFXFile(mix.voice)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Moments of speech in the edited recording (music ducks under them).
    var speech: [[Double]] {
        Subtitles.words(tokens: tokens, states: states, segments: segments, replacements: replacements)
            .map { [$0.start, $0.end] }
    }

    /// The voice and background were separated (stems appeared): lanes change.
    func stemsChanged() {
        revision += 1
        contentRevision += 1
    }

    /// Changes track settings or clips; undoable with ⌘Z.
    func changeMix(_ body: (inout Mix) -> Void) {
        record { body(&$0.mix) }
    }

    /// Track volume while dragging a slider: saved, but not one undo step per pixel.
    func setTrackLive(_ key: String, _ body: (inout TrackSettings) -> Void) {
        var settings = mix.settings(key)
        body(&settings)
        mix.tracks[key] = settings
        revision += 1
        save()
    }

    func replacement(covering index: Int) -> Replacement? {
        replacements.first { $0.first <= index && index <= $0.last }
    }

    private struct Edits: Codable {
        var states: [TokenState]
        var options: CleanOptions
        var replacements: [Replacement]?
        var voiceConsent: Bool?
        var speakerNames: [Int: String]?
        var mix: Mix?
        var speakerOverrides: [Int: Int]?
        var consents: [Int: VoiceConsent]?
        var arrangement: Arrangement?
        var textFixes: [Int: String]?
    }

    init(sourceURL: URL, transcript: Transcript, folder: URL) {
        self.sourceURL = sourceURL
        self.transcript = transcript
        self.folder = folder
        shorts = Shorts.load(from: folder)
        let saved = (try? Data(contentsOf: folder.appendingPathComponent("edits.json")))
            .flatMap { try? JSONDecoder().decode(Edits.self, from: $0) }
        if let saved, saved.states.count == transcript.tokens.count {
            states = saved.states
            options = saved.options
            replacements = saved.replacements ?? []
            voiceConsent = saved.voiceConsent ?? false
            speakerNames = saved.speakerNames ?? [:]
            mix = saved.mix ?? Mix()
            speakerOverrides = saved.speakerOverrides ?? [:]
            consents = saved.consents ?? [:]
            arrangement = saved.arrangement ?? Arrangement()
            textFixes = saved.textFixes ?? [:]
        } else {
            states = Array(repeating: .keep, count: transcript.tokens.count)
            options = CleanOptions()
        }
        tokens = Self.applying(speakerOverrides, textFixes, to: transcript.tokens)
        loading = false
    }

    private static func applying(_ overrides: [Int: Int], _ fixes: [Int: String], to tokens: [Token]) -> [Token] {
        guard !overrides.isEmpty || !fixes.isEmpty else { return tokens }
        var out = tokens
        for (i, speaker) in overrides where i < out.count { out[i].speaker = speaker }
        for (i, text) in fixes where i < out.count { out[i].text = text }
        return out
    }

    /// "These words were said by …": fixes automatic speaker detection by hand (undoable).
    func assignSpeaker(_ indices: [Int], to speaker: Int) {
        guard let first = indices.min(), let last = indices.max() else { return }
        record { snapshot in
            for i in first...last { snapshot.speakerOverrides[i] = speaker }
        }
    }

    // MARK: Editing

    /// Fixes what the transcript says without touching the sound — a misheard word, a name.
    /// The new words take the places of the old ones in order, so each keeps its timing (and
    /// the subtitles stay in step); extra new words join the last place, missing ones leave
    /// their places empty.
    func correctText(_ first: Int, _ last: Int, to text: String) {
        let places = (first...last).filter { transcript.tokens[$0].isWord }
        guard !places.isEmpty else { return }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > places.count {
            words = Array(words[..<(places.count - 1)]) + [words[(places.count - 1)...].joined(separator: " ")]
        }
        record { s in
            for (k, i) in places.enumerated() {
                let new = k < words.count ? words[k] : ""
                s.textFixes[i] = new == transcript.tokens[i].text ? nil : new
            }
        }
    }

    /// The text of these tokens as it is shown now (corrections included).
    func shownText(_ first: Int, _ last: Int) -> String {
        tokens[first...last].filter(\.isWord).compactMap(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Deletes the tokens, or brings them back if all of them were already deleted.
    func toggleDelete(_ indices: [Int]) {
        guard !indices.isEmpty else { return }
        let allDeleted = indices.allSatisfy { states[$0] != .keep }
        change { states in
            for i in indices { states[i] = allDeleted ? .keep : .delete }
        }
    }

    func setState(_ indices: [Int], to state: TokenState) {
        change { states in
            for i in indices { states[i] = state }
        }
    }

    func autoClean() {
        change { states in
            states = Editing.autoClean(tokens: tokens, states: states, options: options)
        }
    }

    func restoreAll() {
        record { s in
            s.states = Array(repeating: .keep, count: s.states.count)
            s.arrangement = Arrangement()
        }
    }

    /// Puts re-voiced words in place of tokens first...last (replacing any overlapping ones).
    func addReplacement(_ r: Replacement) {
        record { snapshot in
            snapshot.replacements.removeAll { !($0.last < r.first || $0.first > r.last) }
            snapshot.replacements.append(r)
        }
    }

    func removeReplacement(_ id: UUID) {
        record { snapshot in snapshot.replacements.removeAll { $0.id == id } }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        apply(next)
    }

    private var current: Snapshot {
        Snapshot(states: states, replacements: replacements, mix: mix, speakerOverrides: speakerOverrides,
                 arrangement: arrangement, textFixes: textFixes)
    }

    private func change(_ body: (inout [TokenState]) -> Void) {
        record { body(&$0.states) }
    }

    private func record(_ body: (inout Snapshot) -> Void) {
        var next = current
        body(&next)
        guard next != current else { return }
        undoStack.append(current)
        redoStack.removeAll()
        apply(next)
    }

    private func apply(_ next: Snapshot) {
        if next.states != states || next.replacements != replacements || next.mix.music != mix.music
            || next.mix.effects != mix.effects || next.speakerOverrides != speakerOverrides
            || next.arrangement != arrangement {
            contentRevision += 1
        }
        if next.speakerOverrides != speakerOverrides || next.textFixes != textFixes {
            speakerOverrides = next.speakerOverrides
            textFixes = next.textFixes
            tokens = Self.applying(speakerOverrides, textFixes, to: transcript.tokens)
        }
        states = next.states
        replacements = next.replacements
        mix = next.mix
        arrangement = next.arrangement
        revision += 1
        save()
    }

    private func save() {
        // `options` and `voiceConsent` save when they change — also while init fills them in,
        // which used to write the edits back before names, volumes and the rest were read
        guard !loading else { return }
        let edits = Edits(states: states, options: options, replacements: replacements,
                          voiceConsent: voiceConsent, speakerNames: speakerNames, mix: mix,
                          speakerOverrides: speakerOverrides, consents: consents,
                          arrangement: arrangement.isEmpty ? nil : arrangement,
                          textFixes: textFixes.isEmpty ? nil : textFixes)
        if let data = try? JSONEncoder().encode(edits) {
            try? data.write(to: folder.appendingPathComponent("edits.json"))
        }
    }

    // MARK: Storage

    /// Folder for one recording, named after its path, size and date so a changed file starts fresh.
    static func folder(for source: URL) -> URL {
        let folder = AppPaths.projects.appendingPathComponent(key(for: source))
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Short id of a file: path, size and date (a changed file gets a new id).
    static func key(for source: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // the same name can come in two Unicode forms (Finder uses decomposed letters): unify first
        let path = source.standardizedFileURL.path.precomposedStringWithCanonicalMapping
        let key = "\(path)|\(size)|\(Int(date))"
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func transcriptURL(in folder: URL) -> URL {
        folder.appendingPathComponent("transcript.json")
    }

    /// Opens a recording that was already transcribed, or returns nil.
    static func load(source: URL) -> Project? {
        let folder = folder(for: source)
        guard let data = try? Data(contentsOf: transcriptURL(in: folder)),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
        else { return nil }
        return Project(sourceURL: source, transcript: transcript, folder: folder)
    }
}

enum AppPaths {
    /// MADSTUDIO_HOME points tests at a separate folder so they never touch the user's projects.
    static var home: URL {
        let override = ProcessInfo.processInfo.environment["MADSTUDIO_HOME"]
        let url = override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MadStudio")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var projects: URL {
        let url = home.appendingPathComponent("projects")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Sound taken out of imported videos.
    static var media: URL {
        let url = home.appendingPathComponent("media")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var logs: URL {
        let url = home.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
