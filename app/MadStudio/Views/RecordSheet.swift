import SwiftUI

/// «Запись голоса»: record straight into the project — no need to bring a file from elsewhere.
struct RecordSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = Recorder()
    @State private var file: URL?
    @State private var problem: String?
    @State private var putOnVoice = true
    @State private var mic = MicSettings.current
    @State private var showSettings = false

    private var voiceIsEmpty: Bool { state.studio?.recording == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Запись голоса").font(.title2.bold())
                Spacer()
                Label(Recorder.inputName, systemImage: "mic").foregroundStyle(Theme.Colors.muted).lineLimit(1)
            }
            VStack(spacing: 10) {
                Text(Format.time(recorder.elapsed))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .foregroundStyle(recorder.isRecording && !recorder.isPaused ? Theme.Colors.accent : Theme.Colors.text)
                meter
                Text(hint).font(.callout).foregroundStyle(recorder.peak > 0.97 ? .red : Theme.Colors.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                if recorder.isRecording {
                    Button { recorder.pause() } label: {
                        Label(recorder.isPaused ? String(localized: "Продолжить") : String(localized: "Пауза"), systemImage: recorder.isPaused ? "record.circle" : "pause.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    Button { finish() } label: {
                        Label("Готово", systemImage: "stop.fill").frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button { Task { await start() } } label: {
                        Label("Начать запись", systemImage: "record.circle").frame(minWidth: 160)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
            HStack {
                Picker("Обработка", selection: Binding(get: { mic.preset }, set: { p in
                    var s = MicSettings.preset(p)
                    if let q = mic.quiet, let l = mic.loud, p != .asIs, p != .custom { s.calibrate(quiet: q, loud: l) }
                    if p == .custom { s = mic; s.preset = .custom }
                    mic = s
                    MicSettings.current = s
                })) {
                    ForEach(MicSettings.Preset.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                .help(mic.preset.about)
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Настройки микрофона: уровень, компрессор, автонастройка под ваш голос")
                    .disabled(recorder.isRecording)
                if mic.quiet != nil {
                    Text("подстроено под голос").font(.caption).foregroundStyle(.green)
                }
            }
            if voiceIsEmpty {
                Toggle("Сразу положить на дорожку голоса и расшифровать", isOn: $putOnVoice)
                    .toggleStyle(.checkbox)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Запись сохраняется в медиатеку проекта. Микрофон выбирается в Системных настройках → Звук → Вход.")
                .font(.caption).foregroundStyle(Theme.Colors.muted)
            HStack {
                Spacer()
                Button(recorder.isRecording ? String(localized: "Отменить запись") : String(localized: "Закрыть")) { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onDisappear { if recorder.isRecording { cancel() } }
        .sheet(isPresented: $showSettings, onDismiss: { mic = MicSettings.current }) { MicSettingsSheet() }
    }

    private var hint: String {
        if !recorder.isRecording { return String(localized: "Говорите на обычном расстоянии от микрофона") }
        if recorder.isPaused { return String(localized: "Пауза — продолжите, когда будете готовы") }
        if recorder.peak > 0.97 { return String(localized: "Слишком громко — звук может искажаться. Отодвиньтесь или убавьте микрофон") }
        if recorder.level < 0.25 { return String(localized: "Тихо — говорите ближе к микрофону") }
        return String(localized: "Идёт запись")
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.panel2)
                Capsule().fill(LinearGradient(colors: [.green, .yellow, Theme.Colors.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(recorder.level))
                Rectangle().fill(recorder.peak > 0.97 ? Color.red : Theme.Colors.text)
                    .frame(width: 2)
                    .offset(x: geo.size.width * CGFloat(recorder.peak) - 1)
                    .opacity(recorder.isRecording ? 1 : 0)
            }
        }
        .frame(width: 320, height: 10)
    }

    private func start() async {
        problem = nil
        guard await Recorder.requestAccess() else {
            problem = String(localized: "Нет доступа к микрофону. Разрешите его: Системные настройки → Конфиденциальность и безопасность → Микрофон → MadStudio.")
            return
        }
        let url = state.newRecordingURL()
        do {
            try recorder.start(to: url)
            file = url
        } catch {
            problem = error.localizedDescription
        }
    }

    private func finish() {
        recorder.stop()
        guard let file else { return }
        let place = voiceIsEmpty && putOnVoice
        let chain = mic.chain
        dismiss()
        Task { await state.addRecording(file, placeOnVoice: place, chain: chain, preset: mic.preset.title) }
    }

    private func cancel() {
        recorder.stop()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        dismiss()
    }
}
