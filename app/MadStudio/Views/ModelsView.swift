import SwiftUI

/// Model library, like LM Studio: a section per task; in each — what is installed and which
/// model is used, and a search on Hugging Face only among models of the family that can do
/// this task (a text model never shows up for re-voicing).
struct ModelsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @AppStorage("modelsTask") private var task = "transcribe"

    struct Section: Identifiable {
        var id: String
        var title: String
        var icon: String
        var about: String
        /// the family the program can run for this task (searched online), nil — catalog only
        var family: String?
    }

    static let sections = [
        Section(id: "transcribe", title: String(localized: "Расшифровка речи"), icon: "waveform",
                about: String(localized: "Превращает речь в текст с временем каждого слова."), family: String(localized: "Whisper в формате MLX")),
        Section(id: "voice", title: String(localized: "Голос автора"), icon: "person.wave.2",
                about: String(localized: "Переозвучка и перевод голосом говорящего."), family: String(localized: "F5-TTS (экспериментально: проверьте на слух)")),
        Section(id: "text", title: String(localized: "Текст"), icon: "text.bubble",
                about: String(localized: "Главы, описание, теги, перевод, моменты для Shorts."), family: String(localized: "языковые модели в формате MLX")),
        Section(id: "separate", title: String(localized: "Голос и фон"), icon: "square.split.2x1",
                about: String(localized: "Отделяет голос от музыки и шумов."), family: nil),
        Section(id: "denoise", title: String(localized: "Шумоподавление"), icon: "wand.and.rays",
                about: String(localized: "Убирает гул, шипение, шум улицы."), family: nil),
        Section(id: "align", title: String(localized: "Разметка слов"), icon: "textformat.abc",
                about: String(localized: "Точные границы слов и проверка «э-э»."), family: String(localized: "wav2vec2 (распознавание по буквам)")),
        Section(id: "speakers", title: String(localized: "Собеседники"), icon: "person.2",
                about: String(localized: "Узнаёт, кто из собеседников где говорит."), family: nil),
        Section(id: "helpers", title: String(localized: "Вспомогательные"), icon: "gearshape.2",
                about: String(localized: "Ставятся вместе с основными: вокодер, ударения, метка ИИ."), family: nil),
    ]

    private var section: Section { Self.sections.first { $0.id == task } ?? Self.sections[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Модели нейросетей").font(.title2.bold())
                    if let d = state.device {
                        Text("Этот Mac: \(d.chip) · \(d.ram_gb) ГБ памяти · свободно \(d.disk_free_gb) ГБ")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !state.modelUpdates.isEmpty {
                    Label("Обновлений: \(state.modelUpdates.count)", systemImage: "arrow.down.circle")
                        .foregroundStyle(Theme.Colors.accent)
                }
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            SpeedPanel()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            ModelsFolderRow()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detail
            }
        }
        .frame(width: 900, height: 660)
        .onAppear {
            // opened because a step needs a model: show that model's section
            if let focus = state.modelsFocus {
                task = Self.sections.contains { $0.id == focus } ? focus : "helpers"
                state.modelsFocus = nil
            }
        }
        .task {
            await state.refreshModels()
            await state.loadModelsFolder()
            async let stats: () = state.loadModelStats()
            await state.checkModelUpdates()
            await stats
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Self.sections) { s in
                let installed = state.models.filter { m in s.id == "helpers" ? m.hidden == true : m.task == s.id && m.hidden != true && m.installed }.count
                Button { task = s.id } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.icon).frame(width: 18)
                        Text(s.title).lineLimit(1)
                        Spacer()
                        if installed > 0 {
                            Text("\(installed)").font(.caption.monospacedDigit()).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(task == s.id ? Theme.Colors.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(task == s.id ? Theme.Colors.accent.opacity(0.4) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 220)
        .background(Theme.Colors.panel)
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.title3.bold())
                    Text(section.about).foregroundStyle(Theme.Colors.muted)
                }
                if task == "helpers" {
                    ForEach(state.models.filter { $0.hidden == true }) { HelperRow(model: $0) }
                } else {
                    Text("На этом Mac").panelHeader()
                    let list = state.models.filter { $0.task == task && $0.hidden != true }
                    if list.isEmpty {
                        Text("Пока ничего — найдите модель ниже.").foregroundStyle(Theme.Colors.muted)
                    }
                    ForEach(list) { ModelRow(model: $0) }
                    if let family = section.family {
                        HubSearch(task: task, family: family)
                    } else {
                        Text("Для этой задачи программа умеет запускать только модели из своего каталога — новые появятся с обновлением MadStudio.")
                            .font(.caption).foregroundStyle(Theme.Colors.muted)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// «Найти в интернете»: models of one family on Hugging Face.
private struct HubSearch: View {
    @Environment(AppState.self) private var state
    let task: String
    let family: String
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 4)
            HStack {
                Text("Найти в интернете").panelHeader()
                Text("· только \(family)").font(.caption).foregroundStyle(Theme.Colors.muted)
            }
            HStack {
                TextField("Например: qwen3, small, russian", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("Искать") { search() }
            }
            if state.hubSearching == task {
                HStack { ProgressView().controlSize(.small); Text("Ищу на Hugging Face…").foregroundStyle(Theme.Colors.muted) }
            } else if let error = state.hubError[task] {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
            }
            ForEach(state.hubResults[task] ?? []) { HubRow(item: $0) }
        }
        .task(id: task) { if state.hubResults[task] == nil { await state.hubSearch(task: task, query: "") } }
    }

    private func search() {
        Task { await state.hubSearch(task: task, query: query) }
    }
}

struct HubRow: View {
    @Environment(AppState.self) private var state
    let item: HubModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.author).font(.caption).foregroundStyle(Theme.Colors.muted)
                    if item.experimental {
                        Text("эксперимент").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2), in: Capsule())
                    }
                }
                Text([item.params_b.map { String(localized: "\(Format.seconds($0)) млрд параметров") }, item.precision,
                      item.size_gb.map { String(localized: "\(Format.seconds($0)) ГБ") }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospaced()).foregroundStyle(Theme.Colors.muted)
                HStack(spacing: 10) {
                    Label(Self.count(item.downloads), systemImage: "arrow.down.circle")
                    Label(item.updated, systemImage: "calendar")
                    if let note = item.note {
                        Text(note).foregroundStyle(item.fit == "ok" ? .green : item.fit == "slow" ? .orange : .red)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.Colors.muted)
            }
            Spacer()
            if let progress = state.downloading[item.repo] {
                ProgressView(value: progress).frame(width: 110)
            } else if item.installed {
                Label("Установлена", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
            } else {
                Button("Скачать") { Task { await state.hubInstall(item) } }
                    .help(item.fit == "ok" ? String(localized: "Скачать и добавить в список") : String(localized: "Можно скачать, но на этом Mac есть ограничения"))
            }
        }
        .padding(10)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.line))
    }

    static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(localized: "\(n / 1_000_000) млн") : n >= 1000 ? String(localized: "\(n / 1000) тыс") : "\(n)"
    }
}

private struct ModelRow: View {
    @Environment(AppState.self) private var state
    let model: ModelInfo

    private var fitColor: Color {
        switch model.fit {
        case "ok": return .green
        case "slow": return .orange
        default: return .red
        }
    }

    private var fitIcon: String {
        switch model.fit {
        case "ok": return "checkmark.circle"
        case "slow": return "tortoise"
        default: return "exclamationmark.triangle"
        }
    }

    private var isActive: Bool { model.chosen == true }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.title).font(.headline)
                    if model.default == true {
                        Text("Рекомендуется")
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(model.description).foregroundStyle(.secondary)
                if let note = model.note {
                    Label(note, systemImage: fitIcon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(fitColor)
                }
                if let technical = model.technical {
                    Text(technical).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("\(Format.seconds(model.size_gb)) ГБ · памяти нужно ~\(Format.seconds(model.ram_gb)) ГБ · русский: \(model.russian) · лицензия \(model.license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let s = state.modelStats[model.id], s.downloads > 0 {
                    Label("\(HubRow.count(s.downloads)) скачиваний за месяц · ♥ \(s.likes)", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Сколько раз модель скачали с Hugging Face за последние 30 дней")
                }
            }
            Spacer()
            if let progress = state.downloading[model.id] {
                ProgressView(value: progress).frame(width: 110)
            } else if model.installed {
                VStack(alignment: .trailing, spacing: 6) {
                    if isActive {
                        Label("Используется", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Использовать") { Task { await state.useModel(model) } }
                    }
                    if state.modelUpdates.contains(model.id) {
                        Button("Обновить") { Task { await state.updateModel(model) } }
                            .buttonStyle(.borderedProminent)
                            .help("На Hugging Face вышла новая версия файлов этой модели")
                    }
                    Button("Удалить", role: .destructive) { Task { await state.remove(model) } }
                        .buttonStyle(.link)
                }
            } else {
                Button("Установить") { Task { await state.install(model) } }
                    .help(model.fit == "ok" ? "" : String(localized: "Можно установить, но на этом компьютере есть ограничения"))
            }
        }
        .padding(.vertical, 6)
    }
}

/// A model installed together with a main one (vocoder, stress marks, AI mark).
private struct HelperRow: View {
    let model: ModelInfo

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.headline)
                Text(model.description).foregroundStyle(.secondary)
                if let technical = model.technical {
                    Text(technical).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("лицензия \(model.license)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.installed ? String(localized: "Установлена") : String(localized: "Не установлена"))
                .font(.caption)
                .foregroundStyle(model.installed ? .green : .secondary)
        }
        .padding(.vertical, 4)
    }
}

/// "Скорость этого Mac": the speed test and how long each kind of work will take here.
struct SpeedPanel: View {
    @Environment(AppState.self) private var state
    @AppStorage("speedPanelOpen") private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                            .font(.caption.weight(.bold)).foregroundStyle(Theme.Colors.muted)
                        Text("Скорость этого Mac").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? String(localized: "Свернуть") : String(localized: "Показать, сколько займёт каждое действие"))
                if let s = state.speed {
                    Text(comparison(s)).foregroundStyle(.secondary)
                }
                Spacer()
                if state.speedTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(state.speed == nil ? String(localized: "Проверить") : String(localized: "Проверить ещё раз")) { Task { await state.runSpeedTest() } }
                        .buttonStyle(.link)
                }
            }
            if open, let s = state.speed {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(s.estimates) { e in
                        GridRow {
                            Text(e.title)
                            Text(Format.duration(e.seconds)).monospacedDigit().bold()
                            Text("на \(e.per)").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                Text("Оценка по короткому тесту видеоядра и памяти и по замерам на MacBook Air M1 8 ГБ.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func comparison(_ s: SpeedInfo) -> String {
        if abs(s.relative - 1) < 0.15 { return String(localized: "— как MacBook Air M1") }
        let x = Format.decimal(s.relative > 1 ? s.relative : 1 / s.relative, digits: 1)
        return s.relative > 1 ? String(localized: "— в \(x) раза быстрее MacBook Air M1") : String(localized: "— в \(x) раза медленнее MacBook Air M1")
    }
}

/// «Где хранятся модели»: the folder, how much it takes, and moving it (e.g. to an external disk).
struct ModelsFolderRow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.modelsFolder?.available == false ? "externaldrive.badge.exclamationmark" : "externaldrive")
                .foregroundStyle(state.modelsFolder?.available == false ? .orange : Theme.Colors.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Где хранятся модели").font(.callout.weight(.semibold))
                if let f = state.modelsFolder {
                    Text(f.available
                         ? String(localized: "\(f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) · занято \(Format.seconds(f.used_gb)) ГБ · свободно \(Format.seconds(f.free_gb)) ГБ")
                         : String(localized: "Папка недоступна: \(f.path) — подключите диск или выберите другую папку"))
                        .font(.caption)
                        .foregroundStyle(f.available ? Theme.Colors.muted : .orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let p = state.movingModels {
                ProgressView(value: p).frame(width: 120)
                Text("Переношу…").font(.caption).foregroundStyle(Theme.Colors.muted)
            } else {
                if state.modelsFolder?.custom == true {
                    Button("Вернуть в MadStudio") { Task { await state.moveModels(to: "") } }
                        .buttonStyle(.link)
                        .help("Перенести модели обратно в папку программы на этом Mac")
                }
                Button("Изменить папку…") { state.chooseModelsFolder() }
                    .help("Выбрать, куда скачивать нейросети — например, на внешний диск. Уже скачанные переедут туда")
            }
        }
        .padding(10)
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}
