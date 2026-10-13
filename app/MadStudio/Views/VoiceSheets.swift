import SwiftUI

/// "Confirm the voice": the person whose voice it is reads a random phrase aloud; the program
/// checks the phrase and that it's the same voice as in the recording. For a guest, the
/// author may instead confirm they have the guest's consent.
struct VoiceCheckSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let speaker: Int

    /// developer check: a file used instead of the microphone, and the phrase it contains
    static var debugFile: URL?
    static var debugPhrase: String?

    private enum Stage: Equatable {
        case ready, recording, checking, passed, failed(String)
    }

    @State private var phrase = ConsentPhrase.make()
    @State private var recorder = Recorder()
    @State private var stage = Stage.ready
    @State private var progress = 0.0
    @State private var name = ""
    @State private var guest = false

    private var whose: String {
        project.speakerCount > 1 ? "«\(project.speakerName(speaker))»" : String(localized: "в этой записи")
    }

    private var recordingURL: URL {
        project.folder.appendingPathComponent("reading.wav")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Подтвердите голос \(whose)").font(.title2.bold())
            Text("MadStudio говорит чужим голосом только с согласия его владельца. Пусть человек, чей это голос, сам прочитает вслух фразу ниже — программа проверит, что фраза прочитана и что голос тот же, что в записи. Подтвердить нужно один раз: в других записях голос узнается сам.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(phrase)
                .font(.title3.weight(.medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Чей это голос:")
                TextField("Имя", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .disabled(stage != .ready)
            action
            Divider()
            if project.speakerCount > 1 || guest {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Это голос гостя, и у меня есть его согласие (например, письменное)", isOn: $guest)
                        .toggleStyle(.checkbox)
                    if guest {
                        Button("Подтвердить согласие гостя") {
                            project.setConsent(.guest, for: speaker)
                            dismiss()
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(stage == .passed ? String(localized: "Готово") : String(localized: "Отмена")) {
                    recorder.stop()
                    dismiss()
                }
                .keyboardShortcut(stage == .passed ? .defaultAction : .cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            name = project.speakerCount > 1 ? project.speakerName(speaker) : String(localized: "Мой голос")
            if let phrase = Self.debugPhrase { self.phrase = phrase }
            if Self.debugFile != nil { Task { await check() } }
        }
        .onDisappear { recorder.stop() }
    }

    @ViewBuilder
    private var action: some View {
        switch stage {
        case .ready:
            Button { Task { await startRecording() } } label: {
                Label("Начать запись", systemImage: "mic.fill").frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        case .recording:
            HStack(spacing: 14) {
                Button { Task { await check() } } label: {
                    Label("Готово", systemImage: "stop.fill").frame(minWidth: 100)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                ProgressView(value: Double(recorder.level)).frame(width: 160)
                Text(Format.time(recorder.elapsed)).monospacedDigit().foregroundStyle(.secondary)
            }
        case .checking:
            VStack(alignment: .leading, spacing: 6) {
                Text("Проверяю фразу и голос…")
                ProgressView(value: progress).frame(width: 300)
            }
        case .passed:
            Label("Голос подтверждён. Теперь можно переозвучивать и переводить этим голосом.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Прочитать ещё раз") {
                    phrase = ConsentPhrase.make()
                    stage = .ready
                }
            }
        }
    }

    private func startRecording() async {
        guard await Recorder.requestAccess() else {
            stage = .failed(String(localized: "Нет доступа к микрофону. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Микрофон → MadStudio."))
            return
        }
        do {
            try recorder.start(to: recordingURL)
            stage = .recording
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func check() async {
        recorder.stop()
        stage = .checking
        progress = 0
        let file = Self.debugFile ?? recordingURL
        do {
            let result = try await state.checkReading(file, phrase: phrase, speaker: speaker,
                                                      name: name.trimmingCharacters(in: .whitespaces),
                                                      project: project) { progress = $0 }
            stage = result.ok ? .passed : .failed(result.problem ?? String(localized: "Не получилось подтвердить голос"))
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }
}

/// One line about a speaker's voice: confirmed or not, and a button to confirm it.
struct VoiceConsentRow: View {
    @Environment(AppState.self) private var state
    let project: Project
    let speaker: Int
    var onConfirm: (Int) -> Void

    var body: some View {
        let who = project.speakerCount > 1 ? project.speakerName(speaker) + ": " : ""
        HStack(spacing: 8) {
            if let label = state.consentLabel(project, speaker: speaker) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(who.isEmpty ? label : who + label.lowercasedFirst)
            } else {
                Image(systemName: "person.badge.key").foregroundStyle(.orange)
                Text(who.isEmpty ? String(localized: "Голос не подтверждён") : who + String(localized: "голос не подтверждён"))
                Spacer()
                Button("Подтвердить…") { onConfirm(speaker) }
            }
        }
    }
}

/// Voices confirmed by reading the phrase: rename or forget.
struct VoicesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Подтверждённые голоса").font(.title2.bold())
            Text("Этими голосами MadStudio может говорить: их владельцы прочитали проверочную фразу. В новых записях такие голоса узнаются сами. Запись чтения хранится как подтверждение согласия.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.voices.isEmpty {
                Text("Пока ни одного. Голос подтверждается при первой переозвучке или переводе.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                ForEach(state.voices) { voice in
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        if renaming == voice.id {
                            TextField("Имя", text: Binding(get: { voice.name }, set: { state.renameVoice(voice.id, to: $0) }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { renaming = nil }
                        } else {
                            Text(voice.name.isEmpty ? String(localized: "Без имени") : voice.name).font(.headline)
                            Button { renaming = voice.id } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help("Переименовать")
                        }
                        Spacer()
                        Text(voice.confirmed.formatted(.dateTime.day().month(.wide).year().locale(AppLanguage.locale)))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) { state.removeVoice(voice.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Забыть голос: в новых записях его нужно будет подтвердить заново")
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack {
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
