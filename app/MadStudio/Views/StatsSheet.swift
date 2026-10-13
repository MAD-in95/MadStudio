import SwiftUI

/// Speech habits per speaker, with a way to remove a parasite word everywhere.
struct StatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project

    private var stats: SpeechStats { SpeechStats(tokens: project.tokens) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Статистика речи").font(.title2.bold())
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(stats.speakers, id: \.id) { s in
                        speakerCard(s)
                    }
                    if stats.takes > 0 {
                        Label("Неудачных дублей (фраза сказана заново): \(stats.takes)", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(.secondary)
                    }
                    Text("Темп — слов в минуту без учёта пауз. Для видео обычно 120–160; быстрее — сложнее воспринимать.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
        .frame(width: 560, height: 560)
    }

    private func speakerCard(_ s: SpeechStats.Speaker) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if stats.speakers.count > 1 {
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: Style.speakerColor(s.id))).frame(width: 10, height: 10)
                    Text(project.speakerName(s.id)).font(.headline)
                }
            }
            HStack(spacing: 24) {
                metric("\(s.pace)", String(localized: "слов в минуту"))
                metric(Format.time(s.speakingTime), String(localized: "говорит"))
                metric(Format.seconds(s.fillersPerMinute), String(localized: "«э-э» в минуту"))
                metric(String(localized: "\(Format.seconds(s.longestPause)) с"), String(localized: "самая длинная пауза"))
            }
            let top = s.parasites.sorted { $0.value > $1.value }.prefix(6)
            if !top.isEmpty {
                Text("Частые слова-паразиты").font(.subheadline.weight(.semibold))
                ForEach(Array(top), id: \.key) { word, count in
                    HStack {
                        Text("«\(word)»")
                        Text("× \(count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Удалить все") {
                            project.setState(SpeechStats.occurrences(of: word, in: project.tokens)
                                .filter { project.tokens[$0].speaker ?? 0 == s.id }, to: .delete)
                        }
                        .help("Вырезать все «\(word)» этого спикера. Отменить — ⌘Z. Проверьте на слух: иногда это слово нужно по смыслу.")
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
