import SwiftUI

/// Asks what to say instead of the selected words, in the speaker's own voice.
struct RevoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Bindable var project: Project
    let first: Int
    let last: Int
    var onRevoice: (String) -> Void

    @State private var text = ""
    @AppStorage("revoiceFine") private var fine = false
    @AppStorage("revoiceSpeed") private var speed = 1.0
    @State private var confirming: Int?
    @State private var recognizing = true

    private var speakers: [Int] { project.speakers(in: first...last) }
    private var allowed: Bool { speakers.allSatisfy { project.mayUseVoice(of: $0) } }

    private var original: String {
        project.tokens[first...last].filter(\.isWord).compactMap(\.text).joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Переозвучить голосом автора").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Было").font(.caption).foregroundStyle(.secondary)
                Text(original.isEmpty ? String(localized: "(пауза или звук)") : original)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Сказать вместо этого").font(.caption).foregroundStyle(.secondary)
                TextField("Новый текст", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Text("Чтобы поправить ударение, поставьте «+» перед ударной гласной: молок+о.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if recognizing && !allowed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Узнаю голос…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(speakers, id: \.self) { speaker in
                    VoiceConsentRow(project: project, speaker: speaker) { confirming = $0 }
                }
            }
            HStack {
                Text("Темп речи")
                Image(systemName: "tortoise").foregroundStyle(.secondary)
                Slider(value: $speed, in: 0.8...1.25, step: 0.05)
                Image(systemName: "hare").foregroundStyle(.secondary)
                Text(abs(speed - 1) < 0.01 ? String(localized: "как у говорящего") : "×\(Format.seconds(speed))")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            }
            .help("Если новые слова звучат торопливо — сдвиньте к черепахе, если вяло — к зайцу. Готовый кусок можно ускорить или замедлить потом")
            let phrase = state.speed?.seconds("revoice") ?? 24
            Picker("Качество", selection: $fine) {
                Text("Обычное — \(Format.duration(phrase))").tag(false)
                Text("Высокое — \(Format.duration(phrase * 2))").tag(true)
            }
            .pickerStyle(.radioGroup)
            .help("По замерам на голосе автора разницы в похожести и разборчивости почти нет; «высокое» — для самых важных фраз")
            Text("\(state.warm.isRunning ? "Голосовая модель уже загружена." : "Первая фраза — ещё ~20 с на загрузку модели.") Новый кусок будет отмечен фиолетовым — его всегда можно вернуть как было.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Переозвучить") {
                    onRevoice(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !allowed)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { text = original }
        .task {
            await state.recognizeVoices(project)
            recognizing = false
        }
        .sheet(item: Binding(get: { confirming.map(SpeakerRef.init) }, set: { confirming = $0?.id })) { ref in
            VoiceCheckSheet(project: project, speaker: ref.id)
        }
    }
}

/// A speaker number usable with `.sheet(item:)`.
struct SpeakerRef: Identifiable {
    let id: Int
}
