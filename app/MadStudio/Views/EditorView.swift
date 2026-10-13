import SwiftUI

struct EditorView: View {
    @Environment(AppState.self) private var state
    let project: Project
    @State private var listenEdited = true
    @State private var selection: [Int] = []
    @State private var revoicing: ClosedRange<Int>?
    /// «Исправить текст»: the words whose spelling is being fixed
    @State private var correcting: ClosedRange<Int>?
    @State private var translating = false
    @AppStorage("sidebarTab") private var sidebarTab = 0
    @AppStorage("textFontSize") private var fontSize = 17.0
    @AppStorage("textFontName") private var fontName = ""
    /// stretch selected on the timeline (also set from the Shorts list)
    @State private var timelineSelection: ClosedRange<Double>?
    /// a Shorts moment being listened to: playback stops at its end
    @State private var playingMoment: ClosedRange<Double>?
    /// developer check: voice confirmation opened at launch
    @State private var demoConfirm: SpeakerRef?
    /// ⌘F
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchIndex = 0

    private var searchMatches: [ClosedRange<Int>] {
        showSearch ? TranscriptSearch.matches(searchQuery, in: project.tokens) : []
    }

    private var player: Player { state.player }

    // the sheets for a range of words (split out: one long body is too much for the compiler)
    private var revoiceItem: Binding<RevoiceRange?> {
        Binding(get: { revoicing.map { RevoiceRange(range: $0) } }, set: { revoicing = $0?.range })
    }
    private var correctItem: Binding<RevoiceRange?> {
        Binding(get: { correcting.map { RevoiceRange(range: $0) } }, set: { correcting = $0?.range })
    }
    private func correctSheet(_ range: ClosedRange<Int>) -> some View {
        CorrectTextSheet(original: project.shownText(range.lowerBound, range.upperBound)) { text in
            project.correctText(range.lowerBound, range.upperBound, to: text)
        }
    }

    /// The text document with its search bar and text style button.
    private var transcript: some View {
        TranscriptView(
            project: project,
            revision: project.revision,
            textStyle: "\(fontName)|\(fontSize)",
            currentTime: originalTime,
            isPlaying: player.isPlaying,
            onClickToken: { playWord(project.tokens[$0].start) },
            onToggleDelete: { project.toggleDelete($0) },
            onSetState: { project.setState($0, to: $1) },
            onSpace: togglePlay,
            onSelect: { selection = $0 },
            onRestore: { project.removeReplacement($0) },
            onTempo: { id, factor in Task { await state.changeTempo(project, replacement: id, factor: factor) } },
            onPlayToken: { playFromToken($0) },
            onRevoice: { startRevoice() },
            onTool: { tool in
                switch tool {
                case "clean": project.autoClean()
                case "stats": state.showStats = true
                case "shorts": state.findShorts()
                case "record": state.showRecorder = true
                case "speak": state.showSpeak = true
                case "find": showSearch = true
                case "correct":
                    if let a = selection.min(), let b = selection.max() { correcting = a...b }
                default: break
                }
            },
            onAssignSpeaker: { project.assignSpeaker($0, to: $1) },
            searchMatches: searchMatches,
            currentMatch: searchMatches.isEmpty ? nil : min(searchIndex, searchMatches.count - 1))
            .frame(minHeight: 160)
            .overlay(alignment: .topTrailing) { TextStyleMenu(size: $fontSize, name: $fontName).padding(10) }
            .overlay(alignment: .top) {
                if showSearch {
                    let matches = searchMatches
                    let indices = matches.flatMap { Array($0) }
                    SearchBar(query: $searchQuery, count: matches.count, current: $searchIndex,
                              allCut: !indices.isEmpty && indices.allSatisfy { project.states[$0] != .keep },
                              onCutAll: { project.toggleDelete(indices) },
                              onClose: { showSearch = false })
                        .padding(.top, 10)
                }
            }
            .background {
                Button("") { showSearch = true }.keyboardShortcut("f").opacity(0)
            }
            .onAppear {
                // developer check: `--search <text>` opens the search with that text
                let args = CommandLine.arguments
                if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
                    searchQuery = args[i + 1]
                    showSearch = true
                }
            }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $sidebarTab) {
                    Text("Медиатека").tag(0)
                    Text("Чистка").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                if sidebarTab == 0 {
                    LibraryPanel(cursor: editedTime)
                } else {
                    ScrollView { CleanupSidebar(project: project) }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
        } detail: {
            VSplitView {
                transcript
                VStack(spacing: 0) {
                    transportBar
                    Divider()
                    TimelineView(project: project, currentTime: editedTime, selection: $timelineSelection,
                                 onSeek: seekEdited, onRevoice: { revoicing = $0 })
                }
                .frame(minHeight: 200, idealHeight: 300)
            }
        }
        .navigationTitle(state.studio?.name ?? project.sourceURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { project.autoClean() } label: {
                    Label("Почистить автоматически", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Убрать паузы, вдохи, «э-э» и щелчки по настройкам во вкладке «Чистка»")
            }
            ToolbarItemGroup {
                Button { state.close() } label: { Label("Закрыть", systemImage: "xmark") }
                    .help("Закрыть проект и вернуться к стартовому окну (правки уже сохранены)")
                Button { startRevoice() } label: {
                    Label("Переозвучить", systemImage: "waveform.and.mic")
                }
                .help("Выделите слова в тексте и скажите их иначе — голосом автора (⌘R)")
                .keyboardShortcut("r")
                .disabled(selection.isEmpty)
                Button { state.showStats = true } label: {
                    Label("Статистика речи", systemImage: "chart.bar")
                }
                .help("Темп, «э-э», паузы и слова-паразиты каждого спикера")
                Button { translating = true } label: {
                    Label("Перевести голосом", systemImage: "globe")
                }
                .help("Перевести запись на другой язык голосом автора")
                Menu {
                    Button("Главы, названия, описание и теги") { Task { await state.makeYouTubeKit() } }
                    Button("Найти моменты для Shorts") { state.findShorts() }
                    if !project.shorts.isEmpty {
                        Button("Показать найденные моменты (\(project.shorts.count))") { state.showShorts = true }
                    }
                } label: {
                    Label("Для YouTube", systemImage: "play.rectangle")
                }
                .help("Главы с таймкодами, названия, описание, теги и моменты для Shorts — по тексту ролика")
                Menu {
                    Button("MP3…") { state.export(as: .mp3) }
                    Button("WAV…") { state.export(as: .wav) }
                    Divider()
                    Button("Субтитры SRT…") { state.exportSubtitles(vtt: false) }
                    Button("Субтитры VTT…") { state.exportSubtitles(vtt: true) }
                    Divider()
                    Button("Текст…") { state.exportText(timecodes: false) }
                    Button("Текст с таймкодами…") { state.exportText(timecodes: true) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Сохранить смонтированную запись (MP3, WAV) или субтитры")
            }
        }
        .sheet(item: revoiceItem) { item in
            RevoiceSheet(project: project, first: item.range.lowerBound, last: item.range.upperBound) { text in
                Task { await state.revoice(project, first: item.range.lowerBound, last: item.range.upperBound, text: text) }
            }
        }
        .sheet(item: correctItem) { item in correctSheet(item.range) }
        .sheet(isPresented: Binding(get: { state.showStats }, set: { state.showStats = $0 })) {
            StatsSheet(project: project)
        }
        .sheet(isPresented: $translating) {
            TranslateSheet(project: project)
        }
        .sheet(isPresented: Binding(get: { state.showDub }, set: { state.showDub = $0 })) {
            if let dub = state.dub { DubSheet(dub: dub) }
        }
        .sheet(isPresented: Binding(get: { state.showYouTube }, set: { state.showYouTube = $0 })) {
            if let kit = state.youtube { YouTubeSheet(kit: kit) }
        }
        .sheet(isPresented: Binding(get: { state.showShorts }, set: { state.showShorts = $0 })) {
            ShortsSheet(project: project, playing: playingMoment, onPlay: playMoment) { range in
                timelineSelection = range
                seekEdited(range.lowerBound)
            }
        }
        .overlay {
            if let progress = state.exportProgress {
                VStack(spacing: 12) {
                    Text(state.busyTitle).font(.headline)
                    ProgressView(value: progress).frame(width: 240)
                    if state.canCancel {
                        Button("Отменить") { state.cancelJob() }
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: project.contentRevision) {
            if player.isPlaying && !player.playingOriginal { play(fromEdited: player.currentTime) }
        }
        .onChange(of: project.mix) {
            player.update(mix: project.mix)
        }
        .onReceive(NotificationCenter.default.publisher(for: .madStudioDemoRevoice)) { note in
            if let range = note.object as? ClosedRange<Int> { revoicing = range }
        }
        .onReceive(NotificationCenter.default.publisher(for: .madStudioDemoConfirmVoice)) { _ in
            demoConfirm = SpeakerRef(id: 0)
        }
        .sheet(item: $demoConfirm) { ref in
            VoiceCheckSheet(project: project, speaker: ref.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .madStudioDemoSelectShort)) { note in
            guard let n = note.object as? Int, n >= 1, n <= project.shorts.count,
                  let range = Shorts.edited(project.shorts[n - 1], segments: project.segments) else { return }
            timelineSelection = range
            seekEdited(range.lowerBound)
        }
        .onChange(of: player.currentTime) {
            guard let moment = playingMoment else { return }
            if !player.isPlaying || player.playingOriginal {
                playingMoment = nil
            } else if player.currentTime >= moment.upperBound {
                player.pause()
                playingMoment = nil
            }
        }
        .onChange(of: listenEdited) {
            let wasPlaying = player.isPlaying
            let t = player.currentTime
            player.pause()
            if listenEdited {
                let edited = player.playingOriginal ? nearestEdited(t) : t
                wasPlaying ? play(fromEdited: edited) : player.seek(to: edited)
            } else {
                let original = player.playingOriginal ? t : (Timeline.originalTime(at: t, segments: project.segments) ?? 0)
                wasPlaying ? player.playOriginal(from: original) : player.seek(to: original)
            }
        }
    }

    /// Time on the original recording (for highlighting words in the text).
    private var originalTime: Double {
        player.playingOriginal ? player.currentTime
            : Timeline.originalTime(at: player.currentTime, segments: project.segments) ?? 0
    }

    /// Time on the edited recording (for the timeline).
    private var editedTime: Double {
        player.playingOriginal ? nearestEdited(player.currentTime) : player.currentTime
    }

    private var transportBar: some View {
        HStack(spacing: 14) {
            Button(action: togglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .help(player.isPlaying ? String(localized: "Пауза (пробел)") : String(localized: "Слушать с курсора (пробел)"))

            Button { state.showRecorder = true } label: {
                Image(systemName: "record.circle").frame(width: 20)
            }
            .buttonStyle(.borderless)
            .font(.title2)
            .foregroundStyle(.red)
            .help("Записать голос с микрофона в медиатеку проекта (⌘⇧R)")

            Text("\(Format.time(player.currentTime)) / \(Format.time(listenEdited ? project.editedDuration : player.originalDuration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $listenEdited) {
                Text("После").tag(true)
                Text("До").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .help("Слушать запись с правками или оригинал")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Edited time of an original moment; a cut moment maps to where the recording continues.
    private func nearestEdited(_ t: Double) -> Double {
        if let e = Timeline.editedTime(of: t, segments: project.segments) { return e }
        var clock = 0.0
        for segment in project.segments {
            if case .original(let r) = segment, r.start >= t { return clock }
            clock += segment.duration
        }
        return clock
    }

    private func startRevoice() {
        guard let first = selection.min(), let last = selection.max() else { return }
        revoicing = first...last
    }

    private func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else if listenEdited {
            let atEnd = player.currentTime >= project.editedDuration - 0.05
            play(fromEdited: atEnd ? 0 : player.currentTime)
        } else {
            let atEnd = player.currentTime >= player.originalDuration - 0.05
            player.playOriginal(from: atEnd ? 0 : player.currentTime)
        }
    }

    /// A click on a word: play from that word.
    /// A click on a word puts the playhead there; playback starts with Space (while it is
    /// already playing, it jumps to the word).
    private func playWord(_ originalStart: Double) {
        let t = listenEdited ? nearestEdited(originalStart) : originalStart
        guard player.isPlaying else {
            player.seek(to: t)
            return
        }
        listenEdited ? play(fromEdited: t) : player.playOriginal(from: t)
    }

    /// «Слушать отсюда» from the menu: plays from the word right away.
    private func playFromToken(_ index: Int) {
        let start = project.tokens[index].start
        if listenEdited { play(fromEdited: nearestEdited(start)) } else { player.playOriginal(from: start) }
    }

    private func seekEdited(_ t: Double) {
        if !listenEdited { listenEdited = true }
        player.isPlaying ? play(fromEdited: t) : player.seek(to: t)
    }

    /// Plays one Shorts moment and stops at its end; pressed again — stops.
    private func playMoment(_ range: ClosedRange<Double>) {
        if playingMoment == range && player.isPlaying {
            player.pause()
            playingMoment = nil
            return
        }
        if !listenEdited { listenEdited = true }
        play(fromEdited: range.lowerBound)
        playingMoment = range
    }

    private func play(fromEdited t: Double) {
        player.play(from: t, lanes: project.lanes, mix: project.mix, speech: project.speech)
    }
}

struct CleanupSidebar: View {
    @Environment(AppState.self) private var state
    @Bindable var project: Project

    private var counts: [TokenKind: Int] {
        Dictionary(grouping: project.tokens, by: \.kind).mapValues(\.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Что убирать").panelHeader()
                Toggle("Длинные паузы (\(longPauses))", isOn: $project.options.pauses)
                Toggle("Вдохи (\(counts[.breath] ?? 0))", isOn: $project.options.breaths)
                Toggle("«Э-э» и мычание (\(fillerCount))", isOn: $project.options.fillers)
                Toggle("Щелчки (\(counts[.click] ?? 0))", isOn: $project.options.clicks)
                Toggle("Неудачные дубли (\(takeCount))", isOn: $project.options.takes)
                    .help("Первая попытка фразы, которую сразу сказали заново. Риторические повторы тоже сюда попадают — проверьте.")
                if project.options.pauses {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Паузы длиннее \(Format.seconds(project.options.maxPause)) с сокращать")
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: $project.options.maxPause, in: 0.4...2.0, step: 0.1)
                    }
                }
            }

            speakersSection

            VStack(alignment: .leading, spacing: 6) {
                Text("Длительность").panelHeader()
                Text("Было: \(Format.time(project.transcript.duration))")
                Text("Стало: \(Format.time(project.editedDuration))")
                let saved = project.transcript.duration - project.editedDuration
                if saved > 0.5 {
                    Text("Убрано: \(Format.time(saved))").foregroundStyle(.secondary)
                }
            }

            Button("Вернуть всё как было") { project.restoreAll() }
                .buttonStyle(.link)

            Spacer()

            Button { state.showModels = true } label: {
                Label("Модели нейросетей", systemImage: "brain")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(Theme.Colors.text)
            .help("Какие нейросети стоят на этом Mac, их размер; установка и удаление")

            VStack(alignment: .leading, spacing: 4) {
                Text("Клик по слову — курсор сюда, пробел — слушать")
                Text("Выделить и Delete — вырезать")
                Text("Выделить и ⌘R — переозвучить")
                Text("Пробел — пауза / пуск")
                Text("Дорожки: тяните куски и их края; C — лезвие, V — стрелка")
                Text("⌘Z — отменить")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    @ViewBuilder
    private var speakersSection: some View {
        if project.speakerCount > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Спикеры").panelHeader()
                ForEach(0..<project.speakerCount, id: \.self) { id in
                    HStack(spacing: 8) {
                        Circle().fill(Color(nsColor: Style.speakerColor(id))).frame(width: 10, height: 10)
                        TextField("Спикер \(id + 1)", text: Binding(
                            get: { project.speakerName(id) },
                            set: { project.renameSpeaker(id, to: $0) }))
                            .textFieldStyle(.plain)
                        if let label = state.consentLabel(project, speaker: id) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).help(label)
                        }
                        if let s = project.transcript.speakers?.seconds?[String(id)] {
                            Text(Format.time(s)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        } else if project.transcript.speakers == nil {
            Button {
                Task { await state.findSpeakers(project) }
            } label: {
                Label("Определить спикеров", systemImage: "person.2")
            }
            .help("Узнать, кто из собеседников где говорит")
        }
    }

    private var takeCount: Int {
        Set(project.tokens.compactMap(\.take)).count
    }

    private var longPauses: Int {
        project.tokens.filter { $0.kind == .pause && $0.duration > project.options.maxPause }.count
    }

    private var fillerCount: Int {
        project.tokens.filter { $0.kind == .filler || $0.parasite == true }.count
    }
}

private struct RevoiceRange: Identifiable {
    let range: ClosedRange<Int>
    var id: Int { range.lowerBound * 100_000 + range.upperBound }
}

/// «Aa» above the text: its size and font.
struct TextStyleMenu: View {
    @Binding var size: Double
    @Binding var name: String

    /// readable faces that come with every Mac
    private static let picks: [(title: String, name: String)] = [
        (String(localized: "Системный (SF Pro)"), ""), ("New York", "NewYork-Regular"), ("Helvetica Neue", "HelveticaNeue"),
        ("Avenir Next", "AvenirNext-Regular"), ("Georgia", "Georgia"), ("PT Sans", "PTSans-Regular"),
        ("PT Serif", "PTSerif-Regular"), (String(localized: "Menlo (моноширинный)"), "Menlo-Regular"),
    ]

    var body: some View {
        Menu {
            Section("Размер: \(Int(size))") {
                Button("Крупнее") { size = min(36, size + 1) }
                Button("Мельче") { size = max(11, size - 1) }
                Button("Обычный (17)") { size = 17 }
            }
            Section("Шрифт") {
                ForEach(Self.picks.filter { $0.name.isEmpty || NSFont(name: $0.name, size: 12) != nil }, id: \.name) { p in
                    Toggle(p.title, isOn: Binding(get: { name == p.name }, set: { if $0 { name = p.name } }))
                }
                Menu("Все шрифты Mac") {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                        Button(family) {
                            name = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first?[0] as? String ?? family
                        }
                    }
                }
            }
        } label: {
            Text("Aa").font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.Colors.panel2.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
        .help("Размер и шрифт текста")
    }
}
