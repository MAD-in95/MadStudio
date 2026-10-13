import SwiftUI

/// Moments the language model picked for Shorts / Reels: listen, show on the timeline,
/// rename, save one or all (audio + subtitles).
struct ShortsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Bindable var project: Project
    /// the moment that is playing now, if any
    var playing: ClosedRange<Double>?
    var onPlay: (ClosedRange<Double>) -> Void
    var onShow: (ClosedRange<Double>) -> Void
    /// the moment whose title is being edited
    @State private var renaming: UUID?

    var body: some View {
        let segments = project.segments
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Моменты для Shorts").font(.title2.bold())
                Spacer()
                Button("Сохранить все…") { state.saveAllShorts() }
                    .disabled(project.shorts.isEmpty)
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            if project.shorts.isEmpty {
                Text("Подходящих моментов не нашлось.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(project.shorts.enumerated()), id: \.element.id) { n, moment in
                            row(n, moment, range: Shorts.edited(moment, segments: segments))
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            Text(String(localized: "Нейросеть на этом Mac выбрала куски по 20–60 секунд, понятные без остального ролика. ")
                 + String(localized: "Названия можно поправить. Моменты отмечены и на дорожке — если потом что-то вырезать, они сдвинутся вместе с текстом."))
                .font(.caption).foregroundStyle(.secondary)
                .padding(20)
        }
        .frame(width: 640, height: 660)
    }

    private func row(_ n: Int, _ moment: ShortMoment, range: ClosedRange<Double>?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(n + 1)")
                    .font(.headline.monospacedDigit())
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Style.shorts.opacity(0.3)))
                if renaming == moment.id {
                    TextField("Название", text: Binding(
                        get: { moment.title },
                        set: { v in if let i = project.shorts.firstIndex(where: { $0.id == moment.id }) { project.shorts[i].title = v } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .onSubmit { renaming = nil }
                } else {
                    Text(moment.title.isEmpty ? String(localized: "Без названия") : moment.title)
                        .font(.headline)
                        .textSelection(.enabled)
                    Button { renaming = moment.id } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Изменить название")
                }
                Spacer(minLength: 4)
                Text(moment.grade)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(gradeColor(moment.score).opacity(0.22)))
                    .help("Как нейросеть оценила момент: \(Int(moment.score)) из 10")
            }
            if let range {
                Text("\(Format.time(range.lowerBound))–\(Format.time(range.upperBound)) · \(Int((range.upperBound - range.lowerBound).rounded())) с")
                    .monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Этот кусок вырезан при монтаже").foregroundStyle(.secondary)
            }
            if !moment.why.isEmpty {
                Text(moment.why).font(.callout)
            }
            Text("«\(moment.text)»")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3)
                .help(moment.text)
            HStack(spacing: 10) {
                let isPlaying = range != nil && playing == range
                Group {
                    Button { if let range { onPlay(range) } } label: {
                        Label(isPlaying ? String(localized: "Стоп") : String(localized: "Слушать"), systemImage: isPlaying ? "stop.fill" : "play.fill")
                    }
                    Button { if let range { onShow(range); dismiss() } } label: {
                        Label("На дорожке", systemImage: "scope")
                    }
                    .help("Выделить этот кусок на дорожках")
                    Button { if let range { state.savePiece(range, name: Shorts.fileName(baseName, number: n + 1, title: moment.title), title: moment.title) } } label: {
                        Label("Сохранить…", systemImage: "square.and.arrow.down")
                    }
                    .help("Сохранить момент: звук с субтитрами или готовое вертикальное видео для Shorts")
                }
                .disabled(range == nil)
                Spacer()
                Button(role: .destructive) {
                    project.shorts.removeAll { $0.id == moment.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Убрать из списка")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var baseName: String {
        project.sourceURL.deletingPathExtension().lastPathComponent
    }

    private func gradeColor(_ score: Double) -> Color {
        score >= 8 ? .green : score >= 7 ? .blue : .gray
    }
}

extension Style {
    /// Moments for Shorts on the timeline and in the list (YouTube Shorts red).
    static let shorts = Color.red
}
