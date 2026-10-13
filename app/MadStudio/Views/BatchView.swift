import SwiftUI

/// Batch processing window: drop many recordings, choose what to clean, get them all saved.
struct BatchView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Bindable var batch: Batch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Пакетная обработка").font(.title2.bold())
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            .padding(20)

            HStack(alignment: .top, spacing: 20) {
                list
                settings.frame(width: 250)
            }
            .padding(.horizontal, 20)

            HStack {
                Text(summary).foregroundStyle(.secondary)
                Spacer()
                if batch.running {
                    Button("Остановить") { batch.stop() }
                } else {
                    Button("Начать") { batch.start(using: state) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(batch.items.isEmpty || batch.outputFolder == nil)
                }
            }
            .padding(20)
        }
        .frame(width: 760, height: 520)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                ForEach(batch.items) { item in
                    HStack {
                        Text(item.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        status(item.status)
                    }
                }
                .onDelete { if !batch.running { batch.items.remove(atOffsets: $0) } }
            }
            .overlay {
                if batch.items.isEmpty {
                    Text("Перетащите сюда записи\nили нажмите «Добавить…»")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                batch.add(urls)
                return true
            }
            Button("Добавить…") { batch.chooseFiles() }.disabled(batch.running)
        }
    }

    @ViewBuilder
    private func status(_ s: Batch.Status) -> some View {
        switch s {
        case .waiting:
            Text("ждёт").foregroundStyle(.secondary)
        case .working(let title, let value):
            HStack(spacing: 6) {
                Text(title).foregroundStyle(.secondary)
                ProgressView(value: value).frame(width: 80)
            }
        case .done(let url):
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label("готово", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
        case .failed(let message):
            Label("ошибка", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private var settings: some View {
        Form {
            Section("Что убирать") {
                Toggle("Длинные паузы", isOn: $batch.options.pauses)
                Toggle("Вдохи", isOn: $batch.options.breaths)
                Toggle("«Э-э» и мычание", isOn: $batch.options.fillers)
                Toggle("Щелчки", isOn: $batch.options.clicks)
                Toggle("Неудачные дубли", isOn: $batch.options.takes)
            }
            Section("Голос") {
                Picker("Шум", selection: $batch.voice.denoise) {
                    Text("Не трогать").tag("off")
                    Text("Убрать слегка").tag("light")
                    Text("Убрать").tag("medium")
                    Text("Убрать полностью").tag("strong")
                }
                Toggle("Радиоголос", isOn: $batch.voice.radio)
            }
            Section("Сохранение") {
                Picker("Громкость", selection: $batch.loudness) {
                    ForEach(AppState.loudnessPresets, id: \.id) { Text($0.title).tag($0.id) }
                }
                Picker("Формат", selection: $batch.format) {
                    Text("MP3").tag("mp3")
                    Text("WAV").tag("wav")
                }
                Toggle("Субтитры SRT рядом", isOn: $batch.subtitles)
                Button(batch.outputFolder?.lastPathComponent ?? String(localized: "Выбрать папку…")) { batch.chooseFolder() }
            }
        }
        .formStyle(.grouped)
        .disabled(batch.running)
    }

    private var summary: String {
        let done = batch.items.filter { if case .done = $0.status { return true } else { return false } }.count
        return batch.items.isEmpty ? String(localized: "Расшифровка ~3 мин на 10 мин записи")
            : String(localized: "Готово \(done) из \(batch.items.count)")
    }
}
