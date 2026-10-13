import AppKit
import SwiftUI

// MARK: - Start window

/// The first window: a new empty project, open one recording, or one of the recent projects.
struct StartView: View {
    @Environment(AppState.self) private var state
    @State private var recent: [RecentItem] = []
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image("Logo").resizable().interpolation(.high).scaledToFit().frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MadStudio").font(.system(size: 30, weight: .bold))
                    Text("Всё обрабатывается на этом Mac").foregroundStyle(Theme.Colors.muted)
                }
            }
            HStack(spacing: 12) {
                choice(String(localized: "Новый проект"), String(localized: "Пустые дорожки — аудио перетаскиваете сами"), icon: "plus", main: true) { state.newProject() }
                choice(String(localized: "Записать голос"), String(localized: "С микрофона, сразу в новый проект"), icon: "mic", main: false) { state.recordNewProject() }
                choice(String(localized: "Открыть запись…"), String(localized: "Сразу расшифровать один файл"), icon: "waveform", main: false) { state.chooseFile() }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Недавние проекты").panelHeader()
                if recent.isEmpty {
                    Text("Пока пусто. Создайте проект или перетащите запись в это окно.")
                        .foregroundStyle(Theme.Colors.muted)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(recent) { item in row(item) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            HStack(spacing: 18) {
                Button { state.showBatch = true } label: { Label("Пакетная обработка", systemImage: "square.stack.3d.up") }
                Button { state.showModels = true } label: { Label("Модели нейросетей", systemImage: "brain") }
                SettingsLink { Label("Настройки · Language", systemImage: "globe") }
            }
            .buttonStyle(.link)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .frame(maxWidth: 760, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.bg)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.Colors.accent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(16)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.open(url)
            return true
        } isTargeted: { targeted = $0 }
        .onAppear { recent = StudioStore.recent() }
    }

    private func choice(_ title: String, _ note: String, icon: String, main: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(note).font(.system(size: 12)).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(main ? Color.white : Theme.Colors.text)
            .background(main ? Theme.Colors.accent : Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(main ? Color.clear : Theme.Colors.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: RecentItem) -> some View {
        Button { state.openRecent(item) } label: {
            HStack(spacing: 12) {
                Text(initials(item.title))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.Colors.panel2, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Theme.Colors.muted)
                }
                Spacer()
                Text(item.date.formatted(.relative(presentation: .named).locale(AppLanguage.locale)))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.Colors.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let doc = item.doc {
                Button("Убрать из списка") {
                    StudioStore.forget(doc.id)
                    recent = StudioStore.recent()
                }
            }
        }
    }

    private func initials(_ title: String) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }.prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}

// MARK: - Media library

/// «Медиатека проекта»: every file brought into the project. Drag a file onto a track
/// (or double-click it); drop files from the Finder here.
struct LibraryPanel: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var targeted = false
    @State private var renaming = false
    @State private var name = ""
    /// where an effect goes when double-clicked (the playhead)
    var cursor: Double = 0

    private var items: [MediaItem] {
        let all = state.studio?.media ?? []
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if renaming {
                    TextField("Название проекта", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { state.renameProject(name); renaming = false }
                } else {
                    Text(state.studio?.name ?? String(localized: "Проект")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Button { name = state.studio?.name ?? ""; renaming = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("Переименовать проект")
                }
                Spacer()
                Button { state.showRecorder = true } label: { Image(systemName: "mic.fill") }
                    .buttonStyle(.borderless).help("Записать голос с микрофона (⌘⇧R)")
                Button { state.showSpeak = true } label: { Image(systemName: "text.bubble") }
                    .buttonStyle(.borderless).help("Озвучить текст подтверждённым голосом (⌘⇧T)")
                Button { state.chooseMedia() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Добавить файлы в медиатеку")
            }
            Text("Медиатека проекта").panelHeader()
            TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).controlSize(.small)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(items) { MediaRow(item: $0, cursor: cursor) }
                }
            }
            .frame(maxHeight: .infinity)
            Text("Перетащите аудио или видео сюда, а отсюда — на дорожку")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(targeted ? Theme.Colors.accent : Theme.Colors.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        }
        .padding(12)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await state.importMedia(urls) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct MediaRow: View {
    @Environment(AppState.self) private var state
    let item: MediaItem
    var cursor: Double
    @State private var wave: [Float] = []

    private var onVoice: Bool { state.studio?.recording == item.path }

    var body: some View {
        HStack(spacing: 8) {
            thumb.frame(width: 38, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "\(Format.time(item.duration)) · \(onVoice ? String(localized: "на дорожке голоса") : kindName)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(onVoice ? Theme.Colors.accent : Theme.Colors.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(onVoice ? Theme.Colors.selection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(onVoice ? Theme.Colors.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .draggable(item.url) {
            Label(item.name, systemImage: "waveform").padding(6).background(Theme.Colors.panel2, in: RoundedRectangle(cornerRadius: 6))
        }
        .onTapGesture(count: 2) { place() }
        .help("Перетащите на дорожку или дважды щёлкните")
        .contextMenu {
            Button("На дорожку голоса (расшифровать)") { state.placeVoice(item) }
            Button("На дорожку музыки") { state.placeClip(item, music: true, at: 0) }
            Button("В эффекты, в место курсора") { state.placeClip(item, music: false, at: cursor) }
            Divider()
            Picker("Тип", selection: Binding(get: { item.kind }, set: { state.setKind($0, of: item.id) })) {
                Text("Речь").tag(MediaItem.Kind.speech)
                Text("Музыка").tag(MediaItem.Kind.music)
                Text("Эффект").tag(MediaItem.Kind.effect)
            }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.original)]) }
            Divider()
            Button("Убрать из медиатеки") { state.removeMedia(item.id) }.disabled(onVoice)
        }
        .task(id: item.path) {
            let cache = StudioStore.folder.appendingPathComponent("wave-\(Project.key(for: item.url)).bin")
            wave = await Waveform.load(source: item.url, cache: cache)
        }
    }

    private var kindName: String {
        switch item.kind {
        case .speech: return String(localized: "речь")
        case .music: return String(localized: "музыка")
        case .effect: return String(localized: "эффект")
        }
    }

    private func place() {
        switch item.kind {
        case .speech: state.placeVoice(item)
        case .music: state.placeClip(item, music: true, at: 0)
        case .effect: state.placeClip(item, music: false, at: cursor)
        }
    }

    private var thumb: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(Theme.Colors.panel2))
            guard !wave.isEmpty else { return }
            let bars = 10
            for b in 0..<bars {
                let a = wave.count * b / bars, z = max(a + 1, wave.count * (b + 1) / bars)
                let level = CGFloat(wave[a..<min(z, wave.count)].max() ?? 0)
                let h = max(2, level * (size.height - 6))
                let w = (size.width - 6) / CGFloat(bars)
                ctx.fill(Path(roundedRect: CGRect(x: 3 + CGFloat(b) * w + 0.5, y: (size.height - h) / 2, width: w - 1, height: h), cornerRadius: 1),
                         with: .color(kindColor))
            }
        }
    }

    private var kindColor: Color {
        switch item.kind {
        case .speech: return Color(nsColor: Style.speakerColor(0))
        case .music: return .green
        case .effect: return .orange
        }
    }
}

// MARK: - A project with empty tracks

/// The project before a recording is on the voice track: the library, an empty document and
/// three tracks that take files from the library or the Finder.
struct BlankProjectView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            LibraryPanel()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VSplitView {
                VStack(spacing: 14) {
                    Image(systemName: "text.word.spacing").font(.system(size: 34)).foregroundStyle(Theme.Colors.muted)
                    Text("Положите запись с речью на дорожку «Голос»").font(.title3.weight(.semibold))
                    Text("Программа расшифрует её, и монтировать можно будет текстом: удалил слово — вырезался звук. Музыку и звуки кладите на свои дорожки.")
                        .foregroundStyle(Theme.Colors.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    HStack {
                        Button { state.showRecorder = true } label: { Label("Записать голос", systemImage: "mic.fill") }
                            .buttonStyle(.borderedProminent)
                        Button("Добавить файлы…") { state.chooseMedia() }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                .background(Theme.Colors.bg)
                EmptyTracks()
                    .frame(minHeight: 200, idealHeight: 260)
            }
        }
        .navigationTitle(state.studio?.name ?? String(localized: "Проект"))
        .toolbar {
            ToolbarItemGroup {
                Button { state.close() } label: { Label("Закрыть", systemImage: "xmark") }
                    .help("Закрыть проект и вернуться к стартовому окну")
            }
        }
    }
}

/// Voice, music and effects tracks of an empty project: drop targets.
struct EmptyTracks: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Дорожки").panelHeader()
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            lane(String(localized: "Голос"), color: Color(nsColor: Style.speakerColor(0)), hint: String(localized: "Перетащите сюда запись с речью"), kind: .speech,
                 clips: [])
            lane(String(localized: "Музыка"), color: .green, hint: String(localized: "Музыка"), kind: .music, clips: state.studio?.pendingMusic ?? [])
            lane(String(localized: "Эффекты"), color: .orange, hint: String(localized: "Звуки и эффекты"), kind: .effect, clips: state.studio?.pendingEffects ?? [])
            Spacer(minLength: 0)
        }
        .background(Theme.Colors.timeline)
    }

    private func lane(_ title: String, color: Color, hint: String, kind: MediaItem.Kind, clips: [UserClip]) -> some View {
        LaneDropTarget(kind: kind) { targeted in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title).font(.callout.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(width: 178)
                Divider()
                ZStack(alignment: .leading) {
                    Text(clips.isEmpty ? hint : clips.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(clips.isEmpty ? Theme.Colors.muted : Theme.Colors.text)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(clips.isEmpty ? Color.clear : color.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                .background(targeted ? Theme.Colors.accent.opacity(0.15) : Color.secondary.opacity(0.05))
            }
            .frame(height: 52)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// A track area that takes files (from the library or the Finder) and puts them on that track.
struct LaneDropTarget<Content: View>: View {
    @Environment(AppState.self) private var state
    let kind: MediaItem.Kind
    var at: Double = 0
    @ViewBuilder var content: (Bool) -> Content
    @State private var targeted = false

    var body: some View {
        content(targeted)
            .dropDestination(for: URL.self) { urls, _ in
                Task { await state.dropOnTrack(urls, kind: kind, at: at) }
                return true
            } isTargeted: { targeted = $0 }
    }
}

extension AppState {
    /// Files dropped on a track: into the library first, then onto that track.
    func dropOnTrack(_ urls: [URL], kind: MediaItem.Kind, at: Double) async {
        let items = await importMedia(urls)
        for item in items {
            switch kind {
            case .speech: placeVoice(item)
            case .music: placeClip(item, music: true, at: at)
            case .effect: placeClip(item, music: false, at: at)
            }
        }
    }
}
