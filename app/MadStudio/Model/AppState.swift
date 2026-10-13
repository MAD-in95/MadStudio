import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppState {
    enum Phase {
        case empty               // the start window
        case blank               // a project with empty tracks
        case processing
        case editing(Project)
    }

    /// The open project: media library and what is on the tracks.
    var studio: StudioDoc?

    init() {
        NotificationCenter.default.addObserver(forName: Engine.missingModel, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated { self?.missingModel = id }
        }
    }

    /// Downloads the model a step was missing; the step can then simply be repeated.
    func downloadMissing() {
        guard let id = missingModel else { return }
        missingModel = nil
        Task {
            if models.isEmpty { await refreshModels() }
            let model = models.first { $0.id == id }
            modelsFocus = model?.task
            showModels = true
            if let model, !model.installed { await install(model) }
        }
    }
    /// a speech recording dropped on the voice track while another one is there: ask first
    var replacingVoice: MediaItem?

    var phase: Phase = .empty
    var errorMessage: String?
    /// the model a step needed and didn't find (the error offers «Скачать»)
    var missingModel: String?
    var infoMessage: String?

    // processing screen
    var stageTitle = ""
    var stageProgress: Double = 0
    var partialText: [String] = []

    // models
    var models: [ModelInfo] = []
    var device: DeviceInfo?
    /// how fast this Mac runs the models (measured once, at the first launch)
    var speed: SpeedInfo? = AppState.loadSpeed()
    var speedTesting = false
    var showModels = false
    /// the section the models window opens on (when a step needs a model)
    var modelsFocus: String?
    var downloading: [String: Double] = [:]
    var transcribeModel: String? {
        get { UserDefaults.standard.string(forKey: "transcribeModel") }
        set { UserDefaults.standard.set(newValue, forKey: "transcribeModel") }
    }
    private var pendingURL: URL?

    // long jobs (export, re-voicing): progress overlay
    var exportProgress: Double?
    var busyTitle = String(localized: "Сохраняю…")
    var canCancel = false

    let player = Player()
    /// keeps the voice model loaded between re-voicings
    let warm = WarmEngine()

    var project: Project? {
        if case .editing(let project) = phase { return project }
        return nil
    }

    static let audioTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    // MARK: Opening

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.message = String(localized: "Выберите запись")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// «Открыть запись…» or a file dropped on the start window: a new project with this
    /// recording on the voice track.
    func open(_ url: URL) {
        player.stop()
        warm.stop()   // another recording: free the memory the voice model takes
        Task {
            if !Pipeline.isPlayableAudio(url) {
                phase = .processing
                partialText = []
                stageTitle = String(localized: "Достаю звук из видео")
                stageProgress = 0
            }
            do {
                var item = try await StudioStore.mediaItem(for: url)
                item.kind = .speech
                var doc = StudioDoc(name: url.deletingPathExtension().lastPathComponent)
                doc.media = [item]
                doc.recording = item.path
                studio = doc
                StudioStore.save(doc)
                openAudio(item.url)
            } catch {
                errorMessage = error.localizedDescription
                phase = .empty
            }
        }
    }

    // MARK: Recording

    var showRecorder = false

    /// Where a new recording of this project goes: «Запись 1 (13 окт, 21-05).wav».
    func newRecordingURL() -> URL {
        let folder = StudioStore.folder.appendingPathComponent("recordings/\(studio?.id.uuidString ?? "без-проекта")")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let n = (studio?.media.filter { $0.name.hasPrefix(String(localized: "Запись ")) }.count ?? 0) + 1
        let f = DateFormatter()
        f.locale = AppLanguage.locale
        f.dateFormat = "d MMM, HH-mm"
        return folder.appendingPathComponent(String(localized: "Запись \(n) (\(f.string(from: Date()))).wav"))
    }

    /// «Записать голос» from the start window: a new project, then the recording window.
    func recordNewProject() {
        newProject()
        showRecorder = true
    }

    /// A finished recording goes into the library (and, if asked, onto the voice track).
    /// With a microphone preset the processed version is the one used; the untouched
    /// recording stays in the library too («… (без обработки)»).
    func addRecording(_ url: URL, placeOnVoice: Bool, chain: String = "", preset: String = "") async {
        var source = url
        if !chain.isEmpty {
            let raw = url.deletingPathExtension().appendingPathExtension("raw.wav")
            let rawNamed = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + String(localized: " (без обработки).wav"))
            busyTitle = String(localized: "Обрабатываю запись («\(preset)»)…")
            exportProgress = 0.5
            do {
                try FileManager.default.moveItem(at: url, to: raw)
                _ = try await Engine.run(["audiofx", raw.path, url.path, chain])
                try FileManager.default.moveItem(at: raw, to: rawNamed)
                await importMedia([rawNamed])
            } catch {
                if FileManager.default.fileExists(atPath: raw.path) { try? FileManager.default.moveItem(at: raw, to: url) }
                errorMessage = String(localized: "Обработка не удалась, запись сохранена как есть: \(error.localizedDescription)")
            }
            exportProgress = nil
            source = url
        }
        guard var item = await importMedia([source]).first else { return }
        item.kind = .speech
        setKind(.speech, of: item.id)
        if placeOnVoice { self.placeVoice(item) }
    }

    // MARK: Projects

    func newProject() {
        player.stop()
        warm.stop()
        let doc = StudioDoc(name: StudioStore.newName())
        StudioStore.save(doc)
        studio = doc
        phase = .blank
    }

    func openRecent(_ item: RecentItem) {
        if let url = item.legacy { return open(url) }
        guard let doc = item.doc else { return }
        player.stop()
        warm.stop()
        studio = doc
        StudioStore.save(doc)
        if let rec = doc.recording, FileManager.default.fileExists(atPath: rec) {
            openAudio(URL(fileURLWithPath: rec))
        } else {
            phase = .blank
        }
    }

    func renameProject(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, studio != nil else { return }
        changeStudio { $0.name = trimmed }
    }

    private func changeStudio(_ body: (inout StudioDoc) -> Void) {
        guard var doc = studio else { return }
        body(&doc)
        studio = doc
        StudioStore.save(doc)
    }

    /// Files brought into the project's media library (videos give their sound).
    @discardableResult
    func importMedia(_ urls: [URL]) async -> [MediaItem] {
        var added: [MediaItem] = []
        for url in urls {
            if let existing = studio?.media.first(where: { $0.original == url.path || $0.path == url.path }) {
                added.append(existing)
                continue
            }
            if !Pipeline.isPlayableAudio(url) {
                busyTitle = String(localized: "Достаю звук из «\(url.lastPathComponent)»…")
                exportProgress = 0
            }
            do {
                let item = try await StudioStore.mediaItem(for: url)
                changeStudio { $0.media.append(item) }
                added.append(item)
            } catch {
                errorMessage = "«\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
            exportProgress = nil
        }
        return added
    }

    func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Добавить в медиатеку проекта")
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importMedia(urls) }
    }

    func setKind(_ kind: MediaItem.Kind, of id: UUID) {
        changeStudio { doc in
            if let i = doc.media.firstIndex(where: { $0.id == id }) { doc.media[i].kind = kind }
        }
    }

    /// Takes a file out of the library (the file itself stays on the disk).
    func removeMedia(_ id: UUID) {
        changeStudio { doc in doc.media.removeAll { $0.id == id && $0.path != doc.recording } }
    }

    /// Puts a speech recording on the voice track: it is transcribed (once) and edited as text.
    func placeVoice(_ item: MediaItem, confirmed: Bool = false) {
        if let current = studio?.recording, current != item.path, !confirmed {
            replacingVoice = item
            return
        }
        replacingVoice = nil
        changeStudio { doc in
            doc.recording = item.path
            if let i = doc.media.firstIndex(where: { $0.id == item.id }) { doc.media[i].kind = .speech }
        }
        player.stop()
        openAudio(item.url)
    }

    /// Music or an effect on its track at time `at` (seconds of the edited recording).
    func placeClip(_ item: MediaItem, music: Bool, at: Double) {
        let length = music && project != nil ? min(item.duration, max(project!.editedDuration - at, 1)) : item.duration
        let clip = UserClip(file: item.path, name: item.name, at: max(0, at), length: length, fileDuration: item.duration,
                            fadeIn: music ? min(1, length / 2) : 0, fadeOut: music ? min(2, length / 2) : 0)
        if let project {
            project.changeMix { mix in if music { mix.music.append(clip) } else { mix.effects.append(clip) } }
        } else {
            changeStudio { doc in if music { doc.pendingMusic.append(clip) } else { doc.pendingEffects.append(clip) } }
        }
    }

    private func openAudio(_ url: URL) {
        if let project = Project.load(source: url) {
            guard project.transcript.version < currentTranscriptVersion else { return show(project) }
            Task { await upgrade(project) }
            return
        }
        Task { await transcribe(url) }
    }

    /// Brings an old transcript up to date without transcribing again (takes a second).
    private func upgrade(_ project: Project) async {
        let path = Project.transcriptURL(in: project.folder).path
        _ = try? await Engine.run(["reanalyze", path])
        show(Project.load(source: project.sourceURL) ?? project)
    }

    private func show(_ project: Project) {
        do {
            try player.load(project.sourceURL)
            // music and effects put on the tracks before the recording was there
            if let doc = studio, !doc.pendingMusic.isEmpty || !doc.pendingEffects.isEmpty {
                project.changeMix { mix in
                    mix.music += doc.pendingMusic
                    mix.effects += doc.pendingEffects
                }
                changeStudio { $0.pendingMusic = []; $0.pendingEffects = [] }
            }
            phase = .editing(project)
        } catch {
            errorMessage = String(localized: "Не получилось открыть запись: \(error.localizedDescription)")
            phase = studio == nil ? .empty : .blank
        }
    }

    /// The transcription model to use, or nil (then the Models window is shown).
    func chosenTranscribeModel() async -> String? {
        await refreshModels()
        let installed = models.filter { $0.task == "transcribe" && $0.installed }
        guard !installed.isEmpty else { return nil }
        return installed.first { $0.chosen == true }?.id ?? installed.first { $0.id == transcribeModel }?.id
            ?? installed.first { $0.default == true }?.id ?? installed[0].id
    }

    private func transcribe(_ url: URL) async {
        guard let model = await chosenTranscribeModel() else {
            pendingURL = url
            modelsFocus = "transcribe"
            showModels = true
            return
        }
        phase = .processing
        partialText = []
        stageTitle = String(localized: "Подготовка…")
        stageProgress = 0
        do {
            show(try await Pipeline.project(for: url, model: model) { [weak self] event in self?.handle(event) })
        } catch {
            errorMessage = error.localizedDescription
            phase = studio == nil ? .empty : .blank
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event.event {
        case "progress":
            let titles = [
                "decode": String(localized: "Читаю запись"),
                "transcribe": String(localized: "Расшифровываю речь"),
                "align": String(localized: "Уточняю границы слов"),
                "speakers": String(localized: "Узнаю голоса собеседников"),
                "voice_load": String(localized: "Загружаю голосовую модель"),
                "voice": String(localized: "Говорю голосом автора"),
                "analyze": String(localized: "Ищу паузы, вдохи и «э-э»"),
                "download": String(localized: "Скачиваю модель"),
                "export": String(localized: "Сохраняю"),
            ]
            stageTitle = titles[event.stage ?? ""] ?? String(localized: "Работаю")
            stageProgress = event.value ?? 0
        case "partial":
            if let text = event.text { partialText.append(text) }
        default:
            break
        }
    }

    func close() {
        player.stop()
        warm.stop()
        studio = nil
        phase = .empty
    }

    // MARK: Models

    private static var speedURL: URL { AppPaths.home.appendingPathComponent("speed.json") }

    private static func loadSpeed() -> SpeedInfo? {
        (try? Data(contentsOf: speedURL)).flatMap {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            return try? d.decode(SpeedInfo.self, from: $0)
        }
    }

    /// A few seconds on the graphics chip; then every estimate in the app fits this Mac.
    func runSpeedTest() async {
        guard !speedTesting else { return }
        speedTesting = true
        defer { speedTesting = false }
        guard let data = try? await Engine.run(["speed-test"]),
              var info = try? JSONDecoder().decode(SpeedInfo.self, from: data) else { return }
        info.date = Date()
        speed = info
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(info).write(to: Self.speedURL)
    }

    func refreshModels() async {
        if device == nil, let data = try? await Engine.run(["device"]) {
            device = try? JSONDecoder().decode(DeviceInfo.self, from: data)
        }
        do {
            let data = try await Engine.run(["models", "list"])
            models = try JSONDecoder().decode([ModelInfo].self, from: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Models online (Hugging Face)

    var hubResults: [String: [HubModel]] = [:]
    var hubSearching: String?
    var hubError: [String: String] = [:]
    /// installed models with newer files on Hugging Face
    var modelUpdates: Set<String> = []

    func hubSearch(task: String, query: String) async {
        hubSearching = task
        defer { hubSearching = nil }
        do {
            let data = try await Engine.run(["hub", "search", task, query])
            hubResults[task] = try JSONDecoder().decode([HubModel].self, from: data)
            hubError[task] = nil
        } catch {
            hubError[task] = String(localized: "Не получилось связаться с Hugging Face. Проверьте интернет.")
        }
    }

    func hubInstall(_ item: HubModel) async {
        downloading[item.repo] = 0
        defer { downloading[item.repo] = nil }
        do {
            _ = try await Engine.run(["hub", "install", item.task, item.repo]) { [weak self] event in
                if event.stage == "download" { self?.downloading[item.repo] = event.value ?? 0 }
            }
            await refreshModels()
            if let i = hubResults[item.task]?.firstIndex(where: { $0.repo == item.repo }) { hubResults[item.task]?[i].installed = true }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// From now on this task runs with this model.
    func useModel(_ model: ModelInfo) async {
        _ = try? await Engine.run(["models", "use", model.id])
        if model.task == "transcribe" { transcribeModel = model.id }
        await refreshModels()
    }

    /// How many people downloaded each catalog model (from Hugging Face, kept for a day).
    var modelStats: [String: (downloads: Int, likes: Int)] = [:]

    func loadModelStats() async {
        guard let data = try? await Engine.run(["hub", "stats"]),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else { return }
        modelStats = raw.mapValues { ($0["downloads"] ?? 0, $0["likes"] ?? 0) }
    }

    // MARK: Models folder

    var modelsFolder: ModelsFolder?
    var movingModels: Double?

    func loadModelsFolder() async {
        guard let data = try? await Engine.run(["models", "where"]) else { return }
        modelsFolder = try? JSONDecoder().decode(ModelsFolder.self, from: data)
    }

    /// The person picks where neural networks are downloaded (e.g. an external disk); the
    /// models already downloaded move there.
    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Хранить здесь")
        panel.message = String(localized: "Где хранить нейросети? Внутри появится папка «MadStudio — модели», уже скачанные модели переедут туда.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await moveModels(to: url.path) }
    }

    func moveModels(to folder: String) async {
        movingModels = 0
        defer { movingModels = nil }
        do {
            let data = try await Engine.run(["models", "move", folder]) { [weak self] e in
                if e.stage == "move" { self?.movingModels = e.value }
            }
            modelsFolder = try? JSONDecoder().decode(ModelsFolder.self, from: data)
            await refreshModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkModelUpdates() async {
        guard let data = try? await Engine.run(["models", "updates"]),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        modelUpdates = Set(list.compactMap { $0["id"] as? String })
    }

    func updateModel(_ model: ModelInfo) async {
        downloading[model.id] = 0
        defer { downloading[model.id] = nil }
        do {
            _ = try await Engine.run(["models", "update", model.id]) { [weak self] event in
                if event.stage == "download" { self?.downloading[model.id] = event.value ?? 0 }
            }
            modelUpdates.remove(model.id)
            await refreshModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install(_ model: ModelInfo) async {
        downloading[model.id] = 0
        defer { downloading[model.id] = nil }
        do {
            _ = try await Engine.run(["models", "install", model.id]) { [weak self] event in
                if event.stage == "download" { self?.downloading[model.id] = event.value ?? 0 }
            }
            if transcribeModel == nil && model.task == "transcribe" { transcribeModel = model.id }
            await refreshModels()
            if let url = pendingURL, models.contains(where: { $0.task == "transcribe" && $0.installed }) {
                pendingURL = nil
                showModels = false
                await transcribe(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ model: ModelInfo) async {
        do {
            _ = try await Engine.run(["models", "remove", model.id])
            if transcribeModel == model.id { transcribeModel = nil }
            await refreshModels()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Re-voicing

    /// Says `text` in place of tokens first...last in the speaker's voice (about a minute).
    /// A re-voiced piece made faster (factor > 1) or slower, without changing the voice's pitch.
    func changeTempo(_ project: Project, replacement id: UUID, factor: Double) async {
        guard let r = project.replacements.first(where: { $0.id == id }) else { return }
        let input = project.folder.appendingPathComponent(r.file)
        let name = "voice/\(UUID().uuidString).wav"
        busyTitle = factor > 1 ? String(localized: "Ускоряю кусок…") : String(localized: "Замедляю кусок…")
        exportProgress = 0.5
        defer { exportProgress = nil }
        do {
            _ = try await Engine.run(["tempo", input.path, project.folder.appendingPathComponent(name).path, String(factor)])
            var next = r
            next.id = UUID()
            next.file = name
            next.duration = r.duration / factor
            next.lead = r.lead.map { $0 / factor }
            next.tail = r.tail.map { $0 / factor }
            next.speed = (r.speed ?? 1) * factor
            project.addReplacement(next)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revoice(_ project: Project, first: Int, last: Int, text: String) async {
        await refreshModels()
        guard models.contains(where: { $0.task == "voice" && $0.installed }) else {
            errorMessage = String(localized: "Для переозвучки нужна голосовая модель. Установите «Голос» в разделе «Модели».")
            showModels = true
            return
        }
        let folder = project.folder.appendingPathComponent("voice")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        let output = folder.appendingPathComponent("\(id.uuidString).wav")
        busyTitle = String(localized: "Говорю голосом автора…")
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            // the tokens with the person's speaker corrections: the voice sample must be the same person
            let fine = UserDefaults.standard.bool(forKey: "revoiceFine")
            let speed = UserDefaults.standard.double(forKey: "revoiceSpeed")
            let data = try await warm.run([
                "revoice", try project.writeTokens().path, project.sourceURL.path,
                String(first), String(last), text, output.path, "--steps", fine ? "32" : "16",
                "--speed", String(speed > 0 ? speed : 1.0),
            ]) { [weak self] event in
                guard let self else { return }
                if event.stage == "voice_load" { self.busyTitle = String(localized: "Загружаю голосовую модель…"); self.exportProgress = 0.05 }
                if event.stage == "voice" { self.busyTitle = String(localized: "Говорю голосом автора…"); self.exportProgress = 0.1 + 0.9 * (event.value ?? 0) }
            }
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let duration = result?["duration"] as? Double ?? 0
            project.addReplacement(Replacement(id: id, first: first, last: last, text: text,
                                               file: "voice/\(id.uuidString).wav", duration: duration,
                                               lead: result?["lead"] as? Double, tail: result?["tail"] as? Double))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Voice confirmation

    /// Voices confirmed by reading a phrase (all projects).
    var voices: [VoiceProfile] = VoiceLibrary.load()
    var showVoices = false

    /// Voice prints of the project's speakers, made once and kept.
    func prints(for project: Project) async throws -> [Int: [Double]] {
        let cached = project.voicePrints
        if !cached.isEmpty { return cached }
        let data = try await Engine.run(["voice-prints", try project.writeTokens().path, project.sourceURL.path])
        struct Answer: Decodable { var prints: [String: [Double]] }
        let raw = try JSONDecoder().decode(Answer.self, from: data).prints
        let prints = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        project.voicePrints = prints
        return prints
    }

    /// Speakers whose voice was already confirmed (in any recording) are recognised and allowed.
    func recognizeVoices(_ project: Project) async {
        guard !voices.isEmpty, project.allSpeakers.contains(where: { !project.mayUseVoice(of: $0) }) else { return }
        await refreshModels()
        guard models.contains(where: { $0.task == "speakers" && $0.installed }),
              let prints = try? await prints(for: project) else { return }
        for (speaker, print) in prints where !project.mayUseVoice(of: speaker) {
            if let match = VoiceLibrary.match(print, in: voices) {
                project.setConsent(.confirmed(match.voice.id), for: speaker)
                if match.similarity >= VoiceLibrary.learn, let i = voices.firstIndex(where: { $0.id == match.voice.id }) {
                    voices[i] = VoiceLibrary.learning(print, into: voices[i])
                    VoiceLibrary.save(voices)
                }
            }
        }
    }

    /// What the program knows about a speaker's voice, for the person.
    func consentLabel(_ project: Project, speaker: Int) -> String? {
        switch project.consents[speaker] {
        case .confirmed(let id) where voices.contains { $0.id == id }:
            let name = voices.first { $0.id == id }?.name ?? ""
            return String(localized: "Голос подтверждён") + (name.isEmpty ? "" : " (\(name))")
        case .guest: return String(localized: "Есть согласие гостя")
        default: return project.voiceConsent ? String(localized: "Согласие подтверждено ранее") : nil
        }
    }

    /// Checks a reading of the phrase: that it was said, and in this speaker's voice. On
    /// success the voice joins the library (with the reading kept as the proof of consent).
    func checkReading(_ recording: URL, phrase: String, speaker: Int, name: String, project: Project,
                      onProgress: @escaping @MainActor (Double) -> Void) async throws -> VoiceCheck {
        await refreshModels()
        for (task, title) in [("speakers", String(localized: "«Спикеры»")), ("transcribe", String(localized: "«Расшифровка»"))]
        where !models.contains(where: { $0.task == task && $0.installed }) {
            throw EngineError.failed(String(localized: "Для проверки голоса нужна модель \(title). Установите её в разделе «Модели нейросетей»."))
        }
        onProgress(0.05)
        let prints = try await prints(for: project)
        var args = ["verify-voice", recording.path, phrase]
        if let print = prints[speaker] {
            let url = project.folder.appendingPathComponent("print-\(speaker).json")
            try JSONEncoder().encode(print).write(to: url)
            args += ["--print", url.path]
        }
        let data = try await Engine.run(args) { event in
            if event.stage == "verify" { onProgress(0.1 + 0.9 * (event.value ?? 0)) }
        }
        let check = try JSONDecoder().decode(VoiceCheck.self, from: data)
        if check.ok {
            let profile = VoiceProfile(name: name, prints: [prints[speaker], check.print].compactMap { $0 }, phrase: phrase)
            let folder = AppPaths.home.appendingPathComponent("voices")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: recording, to: folder.appendingPathComponent("\(profile.id.uuidString).wav"))
            voices.append(profile)
            VoiceLibrary.save(voices)
            project.setConsent(.confirmed(profile.id), for: speaker)
        }
        return check
    }

    func renameVoice(_ id: UUID, to name: String) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].name = name
        VoiceLibrary.save(voices)
    }

    /// Forgets a confirmed voice: it won't be recognised in new recordings any more.
    func removeVoice(_ id: UUID) {
        voices.removeAll { $0.id == id }
        VoiceLibrary.save(voices)
        try? FileManager.default.removeItem(at: AppPaths.home.appendingPathComponent("voices/\(id.uuidString).wav"))
        if let project {
            for (speaker, consent) in project.consents where consent == .confirmed(id) {
                project.setConsent(nil, for: speaker)
            }
        }
    }

    // MARK: Stems

    /// Separates the recording into the voice and the background (music, noises), so the
    /// timeline gets a «Фон записи» track with its own volume.
    func separateStems(_ project: Project) async {
        await refreshModels()
        guard models.contains(where: { $0.task == "separate" && $0.installed }) else {
            errorMessage = String(localized: "Нужна модель «Голос и фон». Установите её в разделе «Модели нейросетей».")
            showModels = true
            return
        }
        let folder = project.folder.appendingPathComponent("stems")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        busyTitle = String(localized: "Отделяю голос от фона…")
        exportProgress = 0
        canCancel = true
        defer { exportProgress = nil; canCancel = false; job = nil }
        let work = Task {
            try await Engine.run(["separate", project.sourceURL.path,
                                  folder.appendingPathComponent("voice.flac").path,
                                  folder.appendingPathComponent("background.flac").path]) { [weak self] event in
                if event.stage == "separate" { self?.exportProgress = event.value }
            }
        }
        // «Отменить» cancels `job`, which passes the cancellation on to the engine run
        job = Task { await withTaskCancellationHandler { _ = await work.result } onCancel: { work.cancel() } }
        do {
            _ = try await work.value
            project.stemsChanged()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Voice processing

    func setVoiceFX(_ fx: VoiceFX, for project: Project) async {
        if fx.denoise != "off" {
            await refreshModels()
            guard models.contains(where: { $0.task == "denoise" && $0.installed }) else {
                errorMessage = String(localized: "Нужна модель «Шумоподавление». Установите её в разделе «Модели нейросетей».")
                showModels = true
                return
            }
        }
        busyTitle = fx.denoise != "off" ? String(localized: "Убираю шум…") : String(localized: "Обрабатываю голос…")
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            try await Pipeline.setVoiceFX(fx, for: project) { [weak self] v in self?.exportProgress = v }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Speakers

    /// Finds who speaks when in a recording transcribed before this feature existed.
    func findSpeakers(_ project: Project) async {
        busyTitle = String(localized: "Узнаю голоса собеседников…")
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            _ = try await Engine.run(["speakers", Project.transcriptURL(in: project.folder).path, project.sourceURL.path]) { [weak self] event in
                if event.stage == "speakers" { self?.exportProgress = event.value }
            }
            if let fresh = Project.load(source: project.sourceURL) { show(fresh) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: AI mark check

    /// Checks any audio file for MadStudio's inaudible AI mark and says where it is.
    func checkWatermark() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.message = String(localized: "Выберите файл, чтобы проверить, есть ли в нём голос, сгенерированный MadStudio")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyTitle = String(localized: "Ищу метку ИИ…")
        exportProgress = 0.5
        Task {
            defer { exportProgress = nil }
            do {
                let data = try await Engine.run(["detect-watermark", url.path])
                let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let segments = result?["segments"] as? [[Double]] ?? []
                if segments.isEmpty {
                    infoMessage = String(localized: "В «\(url.lastPathComponent)» нет звука, сгенерированного MadStudio.")
                } else {
                    let places = segments.map { "\(Format.time($0[0]))–\(Format.time($0[1]))" }.joined(separator: ", ")
                    infoMessage = String(localized: "В «\(url.lastPathComponent)» есть голос, сгенерированный MadStudio: \(places).")
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Translation

    struct Dub: Decodable {
        struct Phrase: Decodable, Identifiable {
            var start: Double
            var end: Double
            var original: String
            var translation: String
            var id: Double { start }
        }
        var path: String
        var subtitles: String
        var phrases: [Phrase]
    }

    static let languages: [(code: String, title: String)] = [
        ("ru", String(localized: "Русский")), ("en", String(localized: "Английский")), ("de", String(localized: "Немецкий")), ("es", String(localized: "Испанский")), ("fr", String(localized: "Французский")),
        ("it", String(localized: "Итальянский")), ("pt", String(localized: "Португальский")), ("tr", String(localized: "Турецкий")), ("uk", String(localized: "Украинский")),
    ]

    var showStats = false
    var showBatch = false
    let batch = Batch()
    var dub: Dub?
    var showDub = false
    private var job: Task<Void, Never>?

    /// Stops a long job (translation) and its engine process.
    func cancelJob() {
        job?.cancel()
    }

    /// Translates the edited recording and says it in the speakers' own voices.
    func translate(_ project: Project, language: String, keepBackground: Bool = true) {
        job = Task { await runTranslation(project, language: language, keepBackground: keepBackground) }
    }

    private func runTranslation(_ project: Project, language: String, keepBackground: Bool) async {
        await refreshModels()
        for (task, name) in [("text", String(localized: "«Текст»")), ("voice", String(localized: "«Голос автора»"))]
        where !models.contains(where: { $0.task == task && $0.installed }) {
            errorMessage = String(localized: "Для перевода нужна модель \(name). Установите её в разделе «Модели нейросетей».")
            showModels = true
            return
        }
        let folder = project.folder.appendingPathComponent("translate")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let edited = folder.appendingPathComponent("edited.wav")
        let wordsURL = folder.appendingPathComponent("words.json")
        let output = folder.appendingPathComponent("\(language).wav")
        busyTitle = String(localized: "Готовлю запись…")
        exportProgress = 0
        canCancel = true
        defer { exportProgress = nil; canCancel = false; job = nil }
        do {
            // 1. the edited recording as one file, and its words in that file's time
            // voices and the recording's own background; the person's music and effects
            // are not part of what gets translated
            try await Pipeline.export(project, to: edited, loudness: nil) { kind in
                switch kind {
                case .speaker, .background: return true
                case .music, .effects: return false
                }
            }
            let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                        segments: project.segments, replacements: project.replacements)
            let json = words.map { ["text": $0.text, "start": $0.start, "end": $0.end, "speaker": $0.speaker ?? 0] as [String: Any] }
            try JSONSerialization.data(withJSONObject: json).write(to: wordsURL)

            // 2. translate and voice
            let name = Self.languages.first { $0.code == language }?.title.lowercased() ?? language
            var args = ["translate", edited.path, wordsURL.path, language, output.path]
            if keepBackground && models.contains(where: { $0.task == "separate" && $0.installed }) {
                args.append("--background")
            }
            let data = try await Engine.run(args) { [weak self] event in
                guard let self else { return }
                switch event.stage {
                case "separate": self.busyTitle = String(localized: "Отделяю голос от музыки и фона…"); self.exportProgress = 0.1 * (event.value ?? 0)
                case "translate_load": self.busyTitle = String(localized: "Загружаю текстовую модель…")
                case "translate": self.busyTitle = String(localized: "Перевожу на \(name)…"); self.exportProgress = 0.1 + 0.05 * (event.value ?? 0)
                case "voice_load": self.busyTitle = String(localized: "Загружаю голосовую модель…"); self.exportProgress = 0.15
                case "dub": self.busyTitle = String(localized: "Говорю на \(name) голосом автора…"); self.exportProgress = 0.15 + 0.85 * (event.value ?? 0)
                default: break
                }
            }
            dub = try JSONDecoder().decode(Dub.self, from: data)
            showDub = true
        } catch is CancellationError {
            // the user stopped it
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves the translated audio (and its subtitles next to it).
    func saveDub(as type: UTType) {
        guard let dub, let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let name = project.sourceURL.deletingPathExtension().lastPathComponent
        let lang = URL(fileURLWithPath: dub.path).deletingPathExtension().lastPathComponent.uppercased()
        panel.nameFieldStringValue = "\(name) (\(lang)).\(type.preferredFilenameExtension ?? "wav")"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        busyTitle = String(localized: "Сохраняю…")
        exportProgress = 0
        Task {
            defer { exportProgress = nil }
            do {
                let planURL = project.folder.appendingPathComponent("translate/save.json")
                let duration = (try? AVAudioFile(forReading: URL(fileURLWithPath: dub.path))).map {
                    Double($0.length) / $0.processingFormat.sampleRate } ?? 0
                try JSONSerialization.data(withJSONObject: ["segments": [["start": 0, "end": duration]]]).write(to: planURL)
                _ = try await Engine.run(["export", dub.path, planURL.path, output.path])
                let srt = output.deletingPathExtension().appendingPathExtension("srt")
                try? FileManager.default.removeItem(at: srt)
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: dub.subtitles), to: srt)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: YouTube

    struct YouTubeKit: Decodable {
        struct Chapter: Decodable { var stamp: String; var title: String }
        var chapters: [Chapter]
        var titles: [String]
        var description: String
        var tags: [String]
    }

    var youtube: YouTubeKit?
    var showYouTube = false

    /// Chapters, titles, description and tags written by the local language model.
    func makeYouTubeKit() async {
        guard let project else { return }
        await refreshModels()
        guard models.contains(where: { $0.task == "text" && $0.installed }) else {
            errorMessage = String(localized: "Нужна текстовая модель. Установите «Текст» в разделе «Модели».")
            showModels = true
            return
        }
        let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                    segments: project.segments, replacements: project.replacements)
        let scriptURL = project.folder.appendingPathComponent("script.txt")
        do {
            try Subtitles.script(words).write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        busyTitle = String(localized: "Загружаю текстовую модель…")
        exportProgress = 0
        defer { exportProgress = nil }
        do {
            let data = try await Engine.run(["youtube", scriptURL.path]) { [weak self] event in
                guard let self, event.stage == "youtube" else { return }
                self.busyTitle = String(localized: "Пишу главы и описание…")
                self.exportProgress = event.value
            }
            youtube = try JSONDecoder().decode(YouTubeKit.self, from: data)
            showYouTube = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Shorts

    var showShorts = false

    /// The language model looks for pieces that work as a Short / Reel on their own.
    func findShorts() {
        guard let project else { return }
        job = Task { await runShorts(project) }
    }

    private func runShorts(_ project: Project) async {
        await refreshModels()
        guard models.contains(where: { $0.task == "text" && $0.installed }) else {
            errorMessage = String(localized: "Нужна текстовая модель. Установите «Текст» в разделе «Модели нейросетей».")
            showModels = true
            return
        }
        let segments = project.segments
        let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                    segments: segments, replacements: project.replacements)
        let wordsURL = project.folder.appendingPathComponent("shorts-words.json")
        busyTitle = String(localized: "Загружаю текстовую модель…")
        exportProgress = 0
        canCancel = true
        defer { exportProgress = nil; canCancel = false; job = nil }
        do {
            try Shorts.wordsJSON(words).write(to: wordsURL)
            let data = try await Engine.run(["shorts", wordsURL.path]) { [weak self] event in
                guard let self, event.stage == "shorts" else { return }
                self.busyTitle = String(localized: "Ищу яркие моменты…")
                self.exportProgress = event.value
            }
            project.shorts = try Shorts.moments(fromEngine: data, segments: segments)
            showShorts = true
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    /// Saves one stretch of the edited recording as its own file, with subtitles next to it.
    func savePiece(_ range: ClosedRange<Double>, name: String, title: String? = nil) {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3, .wav, .mpeg4Movie]
        let format = Self.formatPicker()
        panel.nameFieldStringValue = name + (format.video ? ".mp4" : ".mp3")
        panel.message = String(localized: "Кусок \(Format.time(range.lowerBound))–\(Format.time(range.upperBound)) смонтированной записи. Рядом сохранятся субтитры SRT")
        let loudness = Self.loudnessPicker()
        panel.accessoryView = Self.stack([format.view, loudness.view])
        format.onChange = { video in
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + (video ? ".mp4" : ".mp3")
        }
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let preset = Self.loudnessPresets[loudness.popup.indexOfSelectedItem].id
        UserDefaults.standard.set(preset, forKey: "loudnessPreset")
        let piece = Piece(range: range, output: output, title: title ?? name)
        Task { await savePieces([piece], project: project, loudness: preset) }
    }

    /// Saves every moment for Shorts into one folder: audio and subtitles, or videos, for each.
    func saveAllShorts() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Сохранить сюда")
        panel.message = String(localized: "Каждый момент сохранится отдельным файлом с субтитрами")
        let format = Self.formatPicker()
        let loudness = Self.loudnessPicker()
        panel.accessoryView = Self.stack([format.view, loudness.view])
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let preset = Self.loudnessPresets[loudness.popup.indexOfSelectedItem].id
        UserDefaults.standard.set(preset, forKey: "loudnessPreset")
        let base = project.sourceURL.deletingPathExtension().lastPathComponent
        let segments = project.segments
        let ext = format.video ? "mp4" : "mp3"
        let jobs = project.shorts.enumerated().compactMap { n, m -> Piece? in
            guard let range = Shorts.edited(m, segments: segments) else { return nil }
            let file = folder.appendingPathComponent(Shorts.fileName(base, number: n + 1, title: m.title) + "." + ext)
            return Piece(range: range, output: file, title: m.title)
        }
        Task { await savePieces(jobs, project: project, loudness: preset) }
    }

    struct Piece {
        var range: ClosedRange<Double>
        var output: URL
        var title: String
    }

    func savePieces(_ jobs: [Piece], project: Project, loudness: String, reveal: Bool = true) async {
        guard !jobs.isEmpty else { return }
        busyTitle = jobs.count > 1 ? String(localized: "Сохраняю моменты…") : String(localized: "Сохраняю…")
        exportProgress = 0
        defer { exportProgress = nil }
        let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                    segments: project.segments, replacements: project.replacements)
        do {
            for (n, job) in jobs.enumerated() {
                let report = { [weak self] (v: Double) in self?.exportProgress = (Double(n) + v) / Double(jobs.count) }
                let srt = job.output.deletingPathExtension().appendingPathExtension("srt")
                try Subtitles.srt(Shorts.cues(words, in: job.range)).write(to: srt, atomically: true, encoding: .utf8)
                guard job.output.pathExtension.lowercased() == "mp4" else {
                    try await Pipeline.export(project, to: job.output, loudness: loudness, range: job.range) { report($0) }
                    continue
                }
                // video: the sound first, then the picture around it
                busyTitle = String(localized: "Делаю видео для Shorts…")
                let sound = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).m4a")
                defer { try? FileManager.default.removeItem(at: sound) }
                try await Pipeline.export(project, to: sound, loudness: loudness, range: job.range) { report(0.15 * $0) }
                try await ShortVideo.make(audio: sound, words: Shorts.words(words, in: job.range), title: job.title,
                                          to: job.output) { v in Task { @MainActor in report(0.15 + 0.85 * v) } }
            }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting(jobs.map(\.output)) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "Формат: аудио / видео 9:16" under the file name in the save window.
    final class FormatPicker: NSObject {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        var view: NSView!
        var onChange: (Bool) -> Void = { _ in }
        var video: Bool { popup.indexOfSelectedItem == 1 }
        @objc func changed() {
            UserDefaults.standard.set(video, forKey: "pieceAsVideo")
            onChange(video)
        }
    }

    static func formatPicker() -> FormatPicker {
        let picker = FormatPicker()
        picker.popup.addItems(withTitles: [String(localized: "Аудио (MP3) + субтитры SRT"),
                                           String(localized: "Видео 9:16 с субтитрами (MP4) — для Shorts, Reels, TikTok")])
        picker.popup.selectItem(at: UserDefaults.standard.bool(forKey: "pieceAsVideo") ? 1 : 0)
        picker.popup.target = picker
        picker.popup.action = #selector(FormatPicker.changed)
        let stack = NSStackView(views: [NSTextField(labelWithString: String(localized: "Формат:")), picker.popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 0, right: 16)
        picker.view = stack
        return picker
    }

    static func stack(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 0
        return s
    }

    // MARK: Loudness presets

    static let loudnessPresets: [(id: String, title: String)] = [
        ("none", String(localized: "Как есть")),
        ("youtube", String(localized: "YouTube, VK, Telegram, соцсети (−14 LUFS)")),
        ("podcast", String(localized: "Подкаст: Apple, Spotify, Яндекс (−16 LUFS)")),
        ("broadcast", String(localized: "Радио и ТВ (−23 LUFS)")),
    ]

    /// "Громкость: …" menu shown under the file name in the export window.
    static func loudnessPicker() -> (view: NSView, popup: NSPopUpButton) {
        let label = NSTextField(labelWithString: String(localized: "Громкость:"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: loudnessPresets.map(\.title))
        let saved = UserDefaults.standard.string(forKey: "loudnessPreset") ?? "youtube"
        popup.selectItem(at: loudnessPresets.firstIndex { $0.id == saved } ?? 1)
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return (stack, popup)
    }

    // MARK: Subtitles

    // MARK: Text out and in

    /// The edited text as a file: paragraphs by speaker, optionally with time codes.
    func exportText(timecodes: Bool) {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = String(localized: "\(studio?.name ?? project.sourceURL.deletingPathExtension().lastPathComponent) (текст).txt")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                    segments: project.segments, replacements: project.replacements)
        let names = project.speakerCount > 1 ? (0..<project.speakerCount).map { project.speakerName($0) } : nil
        let text = Subtitles.document(words, names: names, timecodes: timecodes)
        do {
            try text.write(to: output, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var showSpeak = false
    var showMicSettings = false

    /// Reads a text aloud in a confirmed voice; the result goes into the project's library.
    func speak(text: String, voice: VoiceProfile, speed: Double, placeOnVoice: Bool) async {
        if studio == nil { newProject() }
        let reference = AppPaths.home.appendingPathComponent("voices/\(voice.id.uuidString).wav")
        guard FileManager.default.fileExists(atPath: reference.path) else {
            errorMessage = String(localized: "Нет записи чтения для голоса «\(voice.name)». Подтвердите голос заново.")
            return
        }
        let folder = StudioStore.folder.appendingPathComponent("recordings/\(studio?.id.uuidString ?? "")")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(30)) } ?? String(localized: "текст")
        let output = folder.appendingPathComponent(String(localized: "Озвучка — \(first.replacingOccurrences(of: "/", with: " ")).wav"))
        let textFile = folder.appendingPathComponent("speak-\(UUID().uuidString).txt")
        busyTitle = String(localized: "Загружаю голосовую модель…")
        exportProgress = 0
        canCancel = true
        defer { exportProgress = nil; canCancel = false; try? FileManager.default.removeItem(at: textFile) }
        do {
            try text.write(to: textFile, atomically: true, encoding: .utf8)
            _ = try await warm.run(["speak", textFile.path, reference.path, voice.phrase, output.path, "--speed", String(speed)]) { [weak self] e in
                if e.stage == "speak" { self?.busyTitle = String(localized: "Читаю текст голосом «\(voice.name)»…"); self?.exportProgress = e.value }
            }
            await addRecording(output, placeOnVoice: placeOnVoice)
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    /// A new voice for reading texts: its owner reads the phrase; nothing to compare with,
    /// so only the phrase is checked. The reading is the consent and the voice sample.
    func addVoice(reading: URL, phrase: String, name: String) async throws -> VoiceCheck {
        let data = try await Engine.run(["verify-voice", reading.path, phrase])
        let check = try JSONDecoder().decode(VoiceCheck.self, from: data)
        if check.ok, let print = check.print {
            let profile = VoiceProfile(name: name, prints: [print], phrase: phrase)
            let folder = AppPaths.home.appendingPathComponent("voices")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: reading, to: folder.appendingPathComponent("\(profile.id.uuidString).wav"))
            voices.append(profile)
            VoiceLibrary.save(voices)
        }
        return check
    }

    /// Saves subtitles that match the exported (edited) recording.
    func exportSubtitles(vtt: Bool) {
        guard let project else { return }
        let panel = NSSavePanel()
        let ext = vtt ? "vtt" : "srt"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.nameFieldStringValue = String(localized: "\(project.sourceURL.deletingPathExtension().lastPathComponent) (монтаж).\(ext)")
        panel.message = String(localized: "Субтитры совпадают по времени с экспортированной записью (после монтажа)")
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                    segments: project.segments, replacements: project.replacements)
        let cues = Subtitles.cues(words)
        do {
            try (vtt ? Subtitles.vtt(cues) : Subtitles.srt(cues)).write(to: output, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Export

    func export(as type: UTType) {
        guard let project else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let name = project.sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = String(localized: "\(name) (монтаж).\(type.preferredFilenameExtension ?? "wav")")
        let loudness = Self.loudnessPicker()
        panel.accessoryView = loudness.view
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let preset = Self.loudnessPresets[loudness.popup.indexOfSelectedItem].id
        UserDefaults.standard.set(preset, forKey: "loudnessPreset")

        busyTitle = String(localized: "Сохраняю…")
        exportProgress = 0
        Task {
            defer { exportProgress = nil }
            do {
                try await Pipeline.export(project, to: output, loudness: preset) { [weak self] v in
                    self?.exportProgress = v
                }
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
