import SwiftUI
import UniformTypeIdentifiers

/// «Озвучить текст»: paste or open a text, pick a confirmed voice — the voice model reads it
/// and the recording goes into the project's library.
struct SpeakSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var voiceID: UUID?
    @AppStorage("speakSpeed") private var speed = 1.0
    @State private var putOnVoice = true
    @State private var addingVoice = false

    private var voice: VoiceProfile? { state.voices.first { $0.id == voiceID } ?? state.voices.first }

    /// ~10 s of work per second of speech on the M1 (scaled by the speed test).
    private var estimate: String {
        let letters = Double(text.filter(\.isLetter).count)
        let speech = letters / 14 / speed
        let factor = (state.speed?.seconds("revoice") ?? 24) / 24
        return Format.duration(20 + speech * 9 * factor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Озвучить текст").font(.title2.bold())
                Spacer()
                Button { openFile() } label: { Label("Открыть файл…", systemImage: "doc.text") }
                    .help("Взять текст из файла .txt")
            }
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Вставьте текст или откройте файл. Каждый абзац читается отдельно, между абзацами — пауза.")
                            .foregroundStyle(Theme.Colors.muted).padding(14).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 200)
            if state.voices.isEmpty {
                Label("Нужен подтверждённый голос: его владелец один раз читает проверочную фразу.", systemImage: "person.badge.key")
                    .foregroundStyle(.orange)
            } else {
                HStack {
                    Picker("Голос", selection: Binding(get: { voice?.id }, set: { voiceID = $0 })) {
                        ForEach(state.voices) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .frame(width: 260)
                    Button("Добавить голос…") { addingVoice = true }
                        .help("Записать свой голос: прочитать вслух проверочную фразу")
                }
            }
            if state.voices.isEmpty {
                Button { addingVoice = true } label: { Label("Добавить свой голос", systemImage: "mic.fill") }
                    .buttonStyle(.borderedProminent)
            }
            HStack {
                Text("Темп")
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $speed, in: 0.8...1.25, step: 0.05).frame(width: 180)
                Image(systemName: "hare").foregroundStyle(.secondary)
                Text("×\(Format.seconds(speed))").monospacedDigit().foregroundStyle(.secondary)
            }
            if state.studio?.recording == nil {
                Toggle("Положить на дорожку голоса и расшифровать", isOn: $putOnVoice).toggleStyle(.checkbox)
            }
            if !text.isEmpty {
                Label("На этом Mac займёт \(estimate)", systemImage: "clock").foregroundStyle(.orange)
            }
            HStack {
                Text("Озвучка помечается незаметной меткой ИИ.").font(.caption).foregroundStyle(Theme.Colors.muted)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Озвучить") {
                    guard let voice else { return }
                    let (t, s, place) = (text, speed, putOnVoice && state.studio?.recording == nil)
                    dismiss()
                    Task { await state.speak(text: t, voice: voice, speed: s, placeOnVoice: place) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || voice == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheet(isPresented: $addingVoice) { NewVoiceSheet { voiceID = $0 } }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        guard panel.runModal() == .OK, let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content
    }
}

/// A new voice from scratch: read the phrase aloud; it becomes both the consent and the sample.
struct NewVoiceSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var onAdded: (UUID) -> Void
    @State private var phrase = ConsentPhrase.make()
    @State private var name = String(localized: "Мой голос")
    @State private var recorder = Recorder()
    @State private var checking = false
    @State private var problem: String?

    private var file: URL { AppPaths.home.appendingPathComponent("voices/reading-new.wav") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить голос").font(.title2.bold())
            Text("Прочитайте вслух спокойно и чётко, в тишине. Эта запись станет образцом голоса для озвучки и подтверждением, что голос ваш.")
                .foregroundStyle(Theme.Colors.muted).fixedSize(horizontal: false, vertical: true)
            Text(phrase).font(.title3.weight(.medium)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Имя голоса:")
                TextField("Имя", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            HStack(spacing: 12) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Проверяю фразу…")
                } else if recorder.isRecording {
                    Button { Task { await finish() } } label: { Label("Готово", systemImage: "stop.fill") }
                        .buttonStyle(.borderedProminent)
                    ProgressView(value: Double(recorder.level)).frame(width: 160)
                    Text(Format.time(recorder.elapsed)).monospacedDigit()
                } else {
                    Button { Task { await start() } } label: { Label("Начать запись", systemImage: "mic.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена") { recorder.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func start() async {
        problem = nil
        guard await Recorder.requestAccess() else {
            problem = String(localized: "Нет доступа к микрофону: Системные настройки → Конфиденциальность и безопасность → Микрофон.")
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try recorder.start(to: file) } catch { problem = error.localizedDescription }
    }

    private func finish() async {
        recorder.stop()
        checking = true
        defer { checking = false }
        do {
            let check = try await state.addVoice(reading: file, phrase: phrase, name: name)
            if check.ok, let added = state.voices.last {
                onAdded(added.id)
                dismiss()
            } else {
                problem = check.problem
                phrase = ConsentPhrase.make()
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}
