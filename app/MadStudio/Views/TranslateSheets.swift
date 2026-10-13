import AVFoundation
import SwiftUI

/// Choosing the language before translating in the speaker's voice.
struct TranslateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @Bindable var project: Project
    @AppStorage("translateLanguage") private var language = "en"
    @AppStorage("translateKeepBackground") private var keepBackground = true
    /// the recording's own language is not offered (a Russian recording isn't translated into Russian)
    private var targets: [(code: String, title: String)] {
        AppState.languages.filter { $0.code != project.transcript.language }
    }

    /// A phrase every ~7 s of speech; time per phrase and for separation from the speed test.
    private var estimate: String {
        let perPhrase = state.speed?.seconds("translate") ?? 26
        let separation = keepBackground ? project.editedDuration / 600 * (state.speed?.seconds("separate") ?? 120) : 0
        return Format.duration(20 + project.editedDuration / 7 * perPhrase + separation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Перевести голосом автора").font(.title2.bold())
            Picker("Язык", selection: $language) {
                ForEach(targets, id: \.code) { Text($0.title).tag($0.code) }
            }
            .frame(width: 280)
            Text("Переводится смонтированная запись: сначала текст, потом каждая фраза озвучивается голосом того, кто её сказал, с той же интонацией. Рядом сохранятся субтитры перевода.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $keepBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Сохранить музыку и фон")
                    Text("Голос отделяется от музыки и шумов; новый голос звучит поверх оригинального фона")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Label("На этом Mac займёт \(estimate). Можно отменить в любой момент.", systemImage: "clock")
                .foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Перевести") {
                    state.translate(project, language: language, keepBackground: keepBackground)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if !targets.contains(where: { $0.code == language }) { language = targets.first?.code ?? "en" }
        }
    }
}

/// The translated recording: phrases side by side, listen, save.
struct DubSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    let dub: AppState.Dub
    @State private var player: AVAudioPlayer?
    @State private var playing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Перевод готов").font(.title2.bold())
                Spacer()
                Button {
                    toggle()
                } label: {
                    Label(playing ? String(localized: "Пауза") : String(localized: "Слушать"), systemImage: playing ? "pause.fill" : "play.fill")
                }
                Menu("Сохранить") {
                    Button("MP3…") { state.saveDub(as: .mp3) }
                    Button("WAV…") { state.saveDub(as: .wav) }
                }
                .fixedSize()
                Button("Готово") { player?.stop(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            List(dub.phrases) { p in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Format.time(p.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(p.original).foregroundStyle(.secondary)
                    Text(p.translation).font(.body.weight(.medium)).textSelection(.enabled)
                }
                .padding(.vertical, 3)
            }
            Text("Голос сгенерирован ИИ и помечен незаметной меткой. Субтитры перевода сохранятся рядом с файлом.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 620, height: 600)
    }

    private func toggle() {
        if player == nil { player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: dub.path)) }
        guard let player else { return }
        if player.isPlaying { player.pause() } else { player.play() }
        playing = player.isPlaying
    }
}
