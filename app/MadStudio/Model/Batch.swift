import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Many recordings at once: transcribe, clean up automatically and save, one after another.
@Observable
@MainActor
final class Batch {
    enum Status: Equatable {
        case waiting
        case working(String, Double)
        case done(URL)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .waiting
    }

    var items: [Item] = []
    var options = CleanOptions()
    var loudness = UserDefaults.standard.string(forKey: "loudnessPreset") ?? "youtube"
    var format = "mp3"
    var subtitles = true
    var voice = VoiceFX()
    var outputFolder: URL?
    private(set) var running = false
    private var task: Task<Void, Never>?

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url))
        items += urls.filter { !known.contains($0) }.map { Item(url: $0) }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppState.audioTypes
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Выберите записи для пакетной обработки")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Куда сохранить готовые записи")
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    func start(using state: AppState) {
        guard !running, let folder = outputFolder else { return }
        running = true
        task = Task {
            defer { running = false }
            guard let model = await state.chosenTranscribeModel() else {
                state.showModels = true
                return
            }
            for index in items.indices where items[index].status == .waiting || isFailed(items[index]) {
                if Task.isCancelled { break }
                await process(index, model: model, folder: folder)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func isFailed(_ item: Item) -> Bool {
        if case .failed = item.status { return true }
        return false
    }

    private func process(_ index: Int, model: String, folder: URL) async {
        let url = items[index].url
        func set(_ status: Status) { items[index].status = status }
        do {
            set(.working(String(localized: "Достаю звук"), 0))
            let audio = try await Pipeline.audio(for: url)
            set(.working(String(localized: "Расшифровываю"), 0))
            let project = try await Pipeline.project(for: audio, model: model) { [weak self] event in
                guard event.event == "progress", event.stage == "transcribe" else { return }
                self?.items[index].status = .working(String(localized: "Расшифровываю"), event.value ?? 0)
            }
            project.options = options
            project.autoClean()
            if voice.isOn {
                set(.working(String(localized: "Обрабатываю голос"), 0))
                try await Pipeline.setVoiceFX(voice, for: project) { [weak self] v in
                    self?.items[index].status = .working(String(localized: "Обрабатываю голос"), v)
                }
            }
            let name = url.deletingPathExtension().lastPathComponent
            let output = folder.appendingPathComponent(String(localized: "\(name) (монтаж).\(format)"))
            set(.working(String(localized: "Сохраняю"), 0))
            try await Pipeline.export(project, to: output, loudness: loudness) { [weak self] v in
                self?.items[index].status = .working(String(localized: "Сохраняю"), v)
            }
            if subtitles {
                let srt = output.deletingPathExtension().appendingPathExtension("srt")
                try Subtitles.srt(project.subtitleCues).write(to: srt, atomically: true, encoding: .utf8)
            }
            set(.done(output))
        } catch is CancellationError {
            set(.waiting)
        } catch {
            set(.failed(error.localizedDescription))
        }
    }
}
