import AVFoundation
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var state = state
        Group {
            switch state.phase {
            case .empty:
                StartView()
            case .blank:
                BlankProjectView()
            case .processing:
                ProcessingView()
            case .editing(let project):
                EditorView(project: project)
            }
        }
        .task {
            // the first launch: measure this Mac quietly (under a second)
            if state.speed == nil { Task { await state.runSpeedTest() } }
            // `MadStudio --open <file>`: open a recording at launch (handy for testing)
            let args = CommandLine.arguments
            if args.contains("--snapshot") || args.contains("--ui") { DebugSnapshot.log("launch: window ready") }
            DebugSnapshot.scheduleIfRequested()
            if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
                state.open(URL(fileURLWithPath: args[i + 1]))
                if args.contains("--auto-clean") { state.project?.autoClean() }
            }
            if args.contains("--show-models") { state.showModels = true }
            if args.contains("--settings") { openSettings() }
            if args.contains("--recorder") { state.recordNewProject() }
            if args.contains("--speak") { state.showSpeak = true }
            if args.contains("--mic-settings") { state.showMicSettings = true }
            // `--new-project [--import <file> …]`: an empty project, files in its library (developer check)
            if args.contains("--new-project") {
                state.newProject()
                let files = args.indices.filter { args[$0] == "--import" && $0 + 1 < args.count }.map { URL(fileURLWithPath: args[$0 + 1]) }
                await state.importMedia(files)
            }
            if args.contains("--youtube") { await state.makeYouTubeKit() }
            if args.contains("--shorts") { state.findShorts() }
            if args.contains("--show-shorts") { state.showShorts = true }
            // `--confirm-voice <file> --confirm-phrase <text>`: the voice check with a file instead of the mic
            if let i = args.firstIndex(of: "--confirm-voice"), i + 1 < args.count {
                VoiceCheckSheet.debugFile = URL(fileURLWithPath: args[i + 1])
                if let j = args.firstIndex(of: "--confirm-phrase"), j + 1 < args.count {
                    VoiceCheckSheet.debugPhrase = args[j + 1]
                }
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: .madStudioDemoConfirmVoice, object: nil)
            }
            if args.contains("--show-voices") { state.showVoices = true }
            if let i = args.firstIndex(of: "--revoice-test"), i + 1 < args.count, let project = state.project {
                // `--revoice-test 19-23`: re-voice these tokens twice, log how long each took (developer check)
                let parts = args[i + 1].split(separator: "-").compactMap { Int($0) }
                for (n, text) in [String(localized: "Вот, например, звук и подсказки."), String(localized: "Вот, например, волна и тексты.")].enumerated() where parts.count == 2 {
                    let started = Date()
                    await state.revoice(project, first: parts[0], last: parts[1], text: text)
                    DebugSnapshot.log("revoice \(n + 1): \(Int(Date().timeIntervalSince(started))) s, replacements: \(project.replacements.count), error: \(state.errorMessage ?? "none")")
                }
            }
            if let i = args.firstIndex(of: "--revoice-words"), i + 1 < args.count, let project = state.project {
                // `--revoice-words 10-14`: open «Переозвучить» for these tokens (developer check)
                let parts = args[i + 1].split(separator: "-").compactMap { Int($0) }
                if parts.count == 2, parts[0] <= parts[1], parts[1] < project.tokens.count {
                    try? await Task.sleep(for: .seconds(1))
                    NotificationCenter.default.post(name: .madStudioDemoRevoice, object: parts[0]...parts[1])
                }
            }
            if let i = args.firstIndex(of: "--select-short"), i + 1 < args.count, let n = Int(args[i + 1]) {
                try? await Task.sleep(for: .seconds(1))
                NotificationCenter.default.post(name: .madStudioDemoSelectShort, object: n)
            }
            // `--short-to <file>`: save the first Shorts moment (developer check)
            if let i = args.firstIndex(of: "--short-to"), i + 1 < args.count, let project = state.project,
               let moment = project.shorts.first, let range = Shorts.edited(moment, segments: project.segments) {
                let output = URL(fileURLWithPath: args[i + 1])
                try? await Pipeline.export(project, to: output, loudness: "youtube", range: range)
                let words = Subtitles.words(tokens: project.tokens, states: project.states,
                                            segments: project.segments, replacements: project.replacements)
                try? Subtitles.srt(Shorts.cues(words, in: range))
                    .write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            }
            if args.contains("--stats") { state.showStats = true }
            if args.contains("--separate") {
                // test copies only: wait for the transcript, then separate voice and background
                while state.project == nil { try? await Task.sleep(for: .seconds(1)) }
                if let project = state.project { await state.separateStems(project) }
            }
            // test copies only: put music on the Music track, optionally export the mix
            if let i = args.firstIndex(of: "--music"), i + 1 < args.count, let project = state.project {
                let url = URL(fileURLWithPath: args[i + 1])
                if let f = try? AVAudioFile(forReading: url) {
                    let d = Double(f.length) / f.processingFormat.sampleRate
                    project.changeMix {
                        $0.music.append(UserClip(file: url.path, name: url.deletingPathExtension().lastPathComponent,
                                                 at: 0, length: min(d, project.editedDuration), fileDuration: d,
                                                 gainDB: -6, fadeIn: 1, fadeOut: 2))
                    }
                }
                if let j = args.firstIndex(of: "--export-to"), j + 1 < args.count {
                    try? await Pipeline.export(project, to: URL(fileURLWithPath: args[j + 1]), loudness: "youtube")
                }
            }
            if args.contains("--voicefx") {
                // test copies only: wait for the transcript, then clean the voice and export
                while state.project == nil { try? await Task.sleep(for: .seconds(1)) }
                if let project = state.project {
                    await state.setVoiceFX(VoiceFX(denoise: "medium", radio: true), for: project)
                    if let j = args.firstIndex(of: "--fx-export"), j + 1 < args.count {
                        try? await Pipeline.export(project, to: URL(fileURLWithPath: args[j + 1]), loudness: nil)
                    }
                }
            }
            if args.contains("--play"), let project = state.project {
                try? await Task.sleep(for: .seconds(1))
                state.player.play(from: 25, lanes: project.lanes, mix: project.mix, speech: project.speech)
            }
            if args.contains("--batch-demo") {
                // test copies only: two short recordings into a temporary folder
                let files = (ProcessInfo.processInfo.environment["MADSTUDIO_BATCH_FILES"] ?? "").split(separator: "|")
                state.batch.add(files.map { URL(fileURLWithPath: String($0)) })
                state.batch.outputFolder = FileManager.default.temporaryDirectory.appendingPathComponent("madstudio-batch")
                try? FileManager.default.createDirectory(at: state.batch.outputFolder!, withIntermediateDirectories: true)
                state.showBatch = true
                state.batch.start(using: state)
            }
            if args.contains("--translate-demo") {
                // wait for the transcript of a new recording, then translate (test copies only)
                while state.project == nil { try? await Task.sleep(for: .seconds(1)) }
                if let project = state.project {
                    project.voiceConsent = true
                    state.translate(project, language: "en", keepBackground: true)
                }
            }
            if args.contains("--demo"), let project = state.project {
                // a short scripted tour for the progress diary videos
                project.autoClean()
                try? await Task.sleep(for: .seconds(1.5))
                state.player.play(from: 0, lanes: project.lanes, mix: project.mix, speech: project.speech)
                try? await Task.sleep(for: .seconds(4))
                NotificationCenter.default.post(name: .madStudioDemoHover, object: nil)
            }
        }
        .sheet(isPresented: $state.showBatch) {
            BatchView(batch: state.batch)
        }
        .confirmationDialog("Заменить запись на дорожке голоса?", isPresented: Binding(
            get: { state.replacingVoice != nil }, set: { if !$0 { state.replacingVoice = nil } })) {
            Button("Заменить на «\(state.replacingVoice?.name ?? "")»") {
                if let item = state.replacingVoice { state.placeVoice(item, confirmed: true) }
            }
            Button("Отмена", role: .cancel) { state.replacingVoice = nil }
        } message: {
            Text("Правки текущей записи сохранятся: если вернуть её на дорожку, всё будет как было.")
        }
        .sheet(isPresented: $state.showRecorder) {
            RecordSheet()
        }
        .sheet(isPresented: $state.showSpeak) {
            SpeakSheet()
        }
        .sheet(isPresented: $state.showMicSettings) {
            MicSettingsSheet()
        }
        .sheet(isPresented: $state.showVoices) {
            VoicesSheet()
        }
        .sheet(isPresented: $state.showModels) {
            ModelsView()
        }
        .alert("Проверка метки ИИ", isPresented: Binding(
            get: { state.infoMessage != nil },
            set: { if !$0 { state.infoMessage = nil } })
        ) {
            Button("OK") { state.infoMessage = nil }
        } message: {
            Text(state.infoMessage ?? "")
        }
        .overlay {
            if state.project == nil, let progress = state.exportProgress {
                VStack(spacing: 12) {
                    Text(state.busyTitle).font(.headline)
                    ProgressView(value: progress).frame(width: 240)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(state.missingModel == nil ? String(localized: "Что-то пошло не так") : String(localized: "Нужна модель"), isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })
        ) {
            if state.missingModel != nil {
                Button("Скачать") { state.errorMessage = nil; state.downloadMissing() }
                Button("Не сейчас", role: .cancel) { state.errorMessage = nil; state.missingModel = nil }
            } else {
                Button("OK") { state.errorMessage = nil }
            }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

struct DropView: View {
    @Environment(AppState.self) private var state
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 150, height: 150)
            Text("Перетащите запись сюда")
                .font(.title)
            Text("Аудио или видео (из видео возьмём только звук) — всё обрабатывается на этом Mac")
                .foregroundStyle(.secondary)
            Button("Выбрать файл…") { state.chooseFile() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            HStack(spacing: 18) {
                Button { state.showBatch = true } label: {
                    Label("Пакетная обработка", systemImage: "square.stack.3d.up")
                }
                Button { state.showModels = true } label: {
                    Label("Модели нейросетей", systemImage: "brain")
                }
            }
            .buttonStyle(.link)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.3))
                .padding(24)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.open(url)
            return true
        } isTargeted: { targeted = $0 }

    }
}

struct ProcessingView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(state.stageTitle).font(.title2)
            ProgressView(value: state.stageProgress)
            Text("\(Int(state.stageProgress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(state.partialText.joined(separator: " "))
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: state.partialText.count) { proxy.scrollTo("end") }
            }
        }
        .padding(32)
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
