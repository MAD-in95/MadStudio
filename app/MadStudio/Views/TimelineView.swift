import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Multitrack timeline like in editing programs: a lane per speaker, the recording's
/// background, music and effects; ruler, playhead, zoom. Tools as in Premiere: the arrow
/// moves and trims clips (voice clips too — the timeline is "magnetic", the text follows),
/// the razor cuts them, the range tool selects a stretch to cut or save.
struct TimelineView: View {
    @Environment(AppState.self) private var state
    let project: Project
    let currentTime: Double
    @Binding var selection: ClosedRange<Double>?
    var onSeek: (Double) -> Void
    var onRevoice: (ClosedRange<Int>) -> Void = { _ in }

    enum Tool: String { case select, razor, range }
    @State private var tool: Tool = .select     // every launch starts with the arrow
    /// the voice clip picked with the arrow (its tokens)
    @State private var selectedVoice: ClosedRange<Int>?
    @State private var voiceDrag: VoiceDrag?
    /// what the current mouse drag does, decided when it starts
    @State private var gestureKind: GestureKind?
    /// where the mouse is: lane index and time (for the razor line and the right-click menu)
    @State private var hover: (lane: Int, t: Double)?
    /// a pinch in progress: zoom and where the fingers were when it began
    @State private var pinch: (pps: Double, x: Double, offset: Double)?
    @State private var wheelMonitor: Any?

    private enum GestureKind { case voice, user, range, none }

    private struct VoiceDrag {
        var clip: Lane.Clip
        var lane: Int
        var part: ClipDrag.Part
        var dx: Double
        var dy: CGFloat
    }

    @State private var pps: Double = 20                     // pixels per second (zoom)
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var visible: ClosedRange<Double> = 0...60
    @State private var selectedClip: UUID?
    @State private var drag: ClipDrag?
    @State private var waves: [String: [Float]] = [:]
    @FocusState private var focused: Bool

    private let headerWidth: CGFloat = 178
    private let tickHeight: CGFloat = 22
    private let momentsHeight: CGFloat = 18
    /// ticks, plus a strip with the Shorts moments when there are any
    private var rulerHeight: CGFloat { project.shorts.isEmpty ? tickHeight : tickHeight + momentsHeight }
    private let laneHeight: CGFloat = 52

    private struct ClipDrag {
        enum Part { case body, start, end }
        var id: UUID
        var part: Part
        var delta: Double
        var lane = 0
        var dy: CGFloat = 0
    }

    /// The lane a drag that started on lane `from` and moved `dy` points ends on.
    private func targetLane(from: Int, dy: CGFloat) -> Int {
        min(max(0, from + Int((dy / laneHeight).rounded())), lanes.count - 1)
    }

    private var lanes: [Lane] { project.lanes }
    private var length: Double { max(Timeline.duration(lanes), 1) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                headers
                Divider()
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ruler
                            ForEach(Array(lanes.enumerated()), id: \.element.id) { n, lane in laneView(lane, index: n) }
                        }
                        overlay
                    }
                    .frame(width: CGFloat(length + 5) * pps, alignment: .leading)
                    // two-finger pinch on the trackpad zooms around the fingers
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in
                                if pinch == nil { pinch = (pps, Double(v.startLocation.x), visible.lowerBound) }
                                if let p = pinch { zoom(to: p.pps * Double(v.magnification), anchorX: p.x, basePPS: p.pps, offset: p.offset) }
                            }
                            .onEnded { _ in pinch = nil })
                }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ClosedRange<Double>.self) { geo in
                    let start = Double(geo.contentOffset.x) / pps
                    return start...(start + Double(geo.containerSize.width) / pps)
                } action: { _, range in
                    visible = range
                }
            }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // on the Mac the Delete key arrives as the "Delete" command, not as a key press
        .onDeleteCommand { _ = deleteSelection() }
        .onKeyPress(.delete) { deleteSelection() }
        .onKeyPress(.deleteForward) { deleteSelection() }
        .onKeyPress(.escape) {
            selection = nil
            selectedClip = nil
            selectedVoice = nil
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: String(localized: "vcrмср")), phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.characters.lowercased() {
            case "v", "м": tool = .select
            case "c", "с": tool = .razor
            default: tool = .range
            }
            return .handled
        }
        .onChange(of: currentTime) { followPlayhead() }
        .onChange(of: selection) {
            // a stretch selected from elsewhere (a Shorts moment) that is off screen: scroll to it
            guard let s = selection, s.lowerBound > visible.upperBound || s.upperBound < visible.lowerBound else { return }
            scroll.scrollTo(x: CGFloat(max(0, s.lowerBound - 2)) * pps)
        }
        .task(id: project.revision) { await loadWaves() }
        .onAppear {
            // ⌘ + mouse wheel over the tracks zooms too (for a mouse instead of a trackpad)
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard event.modifierFlags.contains(.command), let h = hover else { return event }
                let factor = pow(1.01, Double(event.scrollingDeltaY))
                let x = h.t * pps
                zoom(to: pps * factor, anchorX: x, basePPS: pps, offset: visible.lowerBound)
                return nil
            }
        }
        .onDisappear { if let m = wheelMonitor { NSEvent.removeMonitor(m) } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                toolButton(.select, icon: "cursorarrow",
                           help: String(localized: "Стрелка (V): двигать куски и подрезать их края; перетащить кусок на другую дорожку"))
                toolButton(.razor, icon: "scissors", help: String(localized: "Лезвие (C): щёлкните по куску, чтобы разрезать его. ⌘K — разрезать под курсором"))
                toolButton(.range, icon: "arrow.left.and.right.square",
                           help: String(localized: "Диапазон (R): выделить участок, чтобы вырезать его (Delete) или сохранить отдельным файлом"))
            }
            .padding(2)
            .background(Theme.Colors.panel2, in: RoundedRectangle(cornerRadius: 7))
            Button("") { splitAtPlayhead() }.keyboardShortcut("k", modifiers: .command).hidden().frame(width: 0)
            if project.stems == nil {
                Button {
                    Task { await state.separateStems(project) }
                } label: {
                    Label("Отделить фон", systemImage: "waveform.path.ecg").lineLimit(1)
                }
                .tint(Theme.Colors.text)       // orange is only for the main things
                .help("Разделить запись на голос и фон (музыка, шумы), чтобы менять их громкость отдельно. ~2 мин на 10 мин записи")
            }
            voiceMenu
            Spacer(minLength: 0)
            if let selection {
                Text("\(Format.seconds(selection.upperBound - selection.lowerBound)) с — Delete вырежет")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .layoutPriority(-1)
                Button { savePiece(selection) } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Сохранить выделенный кусок отдельным файлом (например, для Shorts), рядом — субтитры")
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log2(pps) }, set: { pps = pow(2, $0) }), in: 1...8)
                .frame(width: 90)
                .help("Масштаб (⌘− / ⌘+)")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("") { pps = min(256, pps * 1.5) }.keyboardShortcut("=", modifiers: .command).hidden().frame(width: 0)
            Button("") { pps = max(2, pps / 1.5) }.keyboardShortcut("-", modifiers: .command).hidden().frame(width: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Zooms so the moment under `anchorX` (content x at zoom `basePPS`) stays under the fingers.
    private func zoom(to newPPS: Double, anchorX: Double, basePPS: Double, offset: Double) {
        let new = min(256, max(2, newPPS))
        let anchorTime = anchorX / basePPS
        let onScreen = anchorX - offset * basePPS
        pps = new
        scroll.scrollTo(x: CGFloat(max(0, anchorTime * new - onScreen)))
    }

    private func toolButton(_ t: Tool, icon: String, help: String) -> some View {
        Button { tool = t } label: {
            Image(systemName: icon)
                .frame(width: 26, height: 22)
                .foregroundStyle(tool == t ? Color.white : Theme.Colors.text)
                .background(tool == t ? Theme.Colors.accent : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Everyone equally loud: sets the speakers' track volumes, tells what changed.
    private func levelSpeakers() {
        guard let peaks = waves[project.sourceURL.path] else { return }
        let gains = project.levelSpeakers(peaks: peaks)
        if gains.isEmpty {
            state.infoMessage = String(localized: "Выравнивать нечего: у собеседников мало речи, чтобы измерить громкость.")
        } else if gains.values.allSatisfy({ abs($0) < 1 }) {
            state.infoMessage = String(localized: "Собеседники и так звучат одинаково громко — разница меньше 1 дБ.")
        } else {
            let lines = gains.keys.sorted().map { n in
                let g = gains[n] ?? 0
                return "\(project.speakerName(n)): \(g > 0 ? "+" : g < 0 ? "−" : "")\(Format.decimal(abs(g), digits: 1)) " + String(localized: "дБ")
            }
            state.infoMessage = String(localized: "Громкость выровнена: \(lines.joined(separator: ", ")). Отменить — ⌘Z.")
        }
    }

    private var voiceMenu: some View {
        let fx = project.mix.voice
        let label = fx.isOn
            ? String(localized: "Голос: ") + [fx.denoise != "off" ? String(localized: "без шума") : nil, fx.radio ? String(localized: "радио") : nil].compactMap { $0 }.joined(separator: ", ")
            : String(localized: "Обработка голоса")
        return Menu {
            Picker("Шумоподавление", selection: Binding(
                get: { fx.denoise },
                set: { v in var f = fx; f.denoise = v; Task { await state.setVoiceFX(f, for: project) } })) {
                Text("Выключено").tag("off")
                Text("Слабое — оставить немного атмосферы").tag("light")
                Text("Среднее").tag("medium")
                Text("Сильное — убрать весь шум").tag("strong")
            }
            Toggle("Радиоголос — плотнее и чище", isOn: Binding(
                get: { fx.radio },
                set: { v in var f = fx; f.radio = v; Task { await state.setVoiceFX(f, for: project) } }))
            if project.speakerCount > 1 {
                Divider()
                Button("Выровнять громкость собеседников") { levelSpeakers() }
                    .disabled(waves[project.sourceURL.path] == nil)
            }
        } label: {
            Label(label, systemImage: "wand.and.rays").lineLimit(1)
        }
        .tint(Theme.Colors.text)
        .frame(maxWidth: 220)
        .help("Убрать шум из голоса и сделать его «как на радио». Оригинал не меняется — можно выключить в любой момент")
    }

    // MARK: Track headers

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(lanes) { lane in
                header(lane)
                    .frame(height: laneHeight)
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
        .frame(width: headerWidth)
    }

    private func header(_ lane: Lane) -> some View {
        let settings = project.mix.settings(lane.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color(lane.kind)).frame(width: 8, height: 8)
                Text(title(lane.kind)).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 2)
                toggle("M", key: lane.id, on: settings.muted, help: String(localized: "Выключить звук дорожки")) { $0.muted.toggle() }
                toggle("S", key: lane.id, on: settings.solo, help: String(localized: "Слушать только эту дорожку")) { $0.solo.toggle() }
            }
            HStack(spacing: 4) {
                Slider(value: Binding(get: { settings.gainDB },
                                      set: { v in project.setTrackLive(lane.id) { $0.gainDB = v.rounded() } }),
                       in: -30...12)
                    .controlSize(.mini)
                Text("\(Int(settings.gainDB)) дБ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                extra(lane.kind)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func extra(_ kind: Lane.Kind) -> some View {
        switch kind {
        case .music:
            Menu {
                Button("Добавить музыку…") { addClip(to: .music, at: 0) }
                Toggle("Приглушать под речью", isOn: Binding(
                    get: { project.mix.duck },
                    set: { v in project.changeMix { $0.duck = v } }))
                Picker("Насколько тише", selection: Binding(
                    get: { project.mix.duckDepth },
                    set: { v in project.changeMix { $0.duckDepth = v } })) {
                    Text("−6 дБ").tag(6.0)
                    Text("−12 дБ").tag(12.0)
                    Text("−18 дБ").tag(18.0)
                }
            } label: { Image(systemName: "plus.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Добавить музыку; приглушение под речью")
        case .effects:
            Button { addClip(to: .effects, at: currentTime) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("Добавить звук в место курсора")
        default:
            EmptyView()
        }
    }

    private func toggle(_ letter: String, key: String, on: Bool, help: String,
                        _ change: @escaping (inout TrackSettings) -> Void) -> some View {
        Button {
            project.changeMix { mix in
                var s = mix.settings(key)
                change(&s)
                mix.tracks[key] = s
            }
        } label: {
            Text(letter)
                .font(.caption.bold())
                .frame(width: 18, height: 16)
                .background(on ? (letter == "M" ? Color.orange : Color.yellow).opacity(0.85) : Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(on ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Ruler and lanes

    private var ruler: some View {
        let moments = momentRanges
        return Canvas { ctx, size in
            // Shorts moments: red bands with their number and title, under the ticks
            for m in moments where m.range.upperBound >= visible.lowerBound && m.range.lowerBound <= visible.upperBound {
                let rect = CGRect(x: CGFloat(m.range.lowerBound) * pps, y: tickHeight + 1,
                                  width: max(2, CGFloat(m.range.upperBound - m.range.lowerBound) * pps), height: momentsHeight - 3)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Style.shorts.opacity(0.28)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Style.shorts.opacity(0.8)), lineWidth: 1)
                let label = rect.width > 60 ? "\(m.number) · \(m.title)" : "\(m.number)"
                var inner = ctx
                inner.clip(to: Path(rect.insetBy(dx: 3, dy: 0)))
                inner.draw(Text(label).font(.caption2.weight(.medium)).foregroundStyle(.primary),
                           at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
            }
            let step = rulerStep()
            var t = (visible.lowerBound / step).rounded(.down) * step
            while t <= visible.upperBound + step {
                let x = CGFloat(t) * pps
                ctx.fill(Path(CGRect(x: x, y: tickHeight - 6, width: 1, height: 6)), with: .color(.secondary))
                ctx.draw(Text(Format.time(t)).font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                t += step
            }
        }
        .frame(height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if v.translation == .zero { takeKeyboard() }
                if v.startLocation.y > tickHeight && moment(at: v.startLocation) != nil { return }
                onSeek(max(0, Double(v.location.x) / pps))
            }
            .onEnded { v in
                // a click on a Shorts moment selects it (ready to save or listen)
                guard v.startLocation.y > tickHeight, let m = moment(at: v.startLocation) else { return }
                focused = true
                selection = m.range
                onSeek(m.range.lowerBound)
            })
        .help(moments.isEmpty ? "" : String(localized: "Красные отметки — моменты для Shorts. Клик — выделить кусок"))
    }

    private struct MomentMark {
        var number: Int
        var range: ClosedRange<Double>
        var title: String
    }

    /// Shorts moments where they are in the edited recording now.
    private var momentRanges: [MomentMark] {
        guard !project.shorts.isEmpty else { return [] }
        let segments = project.segments
        return project.shorts.enumerated().compactMap { n, m in
            Shorts.edited(m, segments: segments).map { MomentMark(number: n + 1, range: $0, title: m.title) }
        }
    }

    private func moment(at point: CGPoint) -> MomentMark? {
        let t = Double(point.x) / pps
        return momentRanges.first { $0.range.contains(t) }
    }

    /// Saves the selected stretch as its own file; a Shorts moment keeps its name.
    private func savePiece(_ range: ClosedRange<Double>) {
        let base = project.sourceURL.deletingPathExtension().lastPathComponent
        if let m = momentRanges.first(where: { abs($0.range.lowerBound - range.lowerBound) < 0.01
                                               && abs($0.range.upperBound - range.upperBound) < 0.01 }) {
            state.savePiece(range, name: Shorts.fileName(base, number: m.number, title: m.title), title: m.title)
        } else {
            state.savePiece(range, name: String(localized: "\(base) — кусок \(Int(range.lowerBound))-\(Int(range.upperBound.rounded())) с"))
        }
    }

    private func laneView(_ lane: Lane, index: Int) -> some View {
        Canvas { ctx, size in
            for clip in lane.clips where clip.end >= visible.lowerBound - 1 && clip.at <= visible.upperBound + 1 {
                draw(clip: shifted(clip), lane: lane, in: &ctx, height: size.height)
            }
        }
        .frame(height: laneHeight)
        .background(Color.secondary.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(laneGesture(lane, index: index))
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let t = Double(p.x) / pps
                hover = (index, t)
                cursor(lane, at: t).set()
            case .ended:
                hover = nil
                NSCursor.arrow.set()
            }
        }
        .contextMenu { clipMenu(lane) }
        .dropDestination(for: URL.self) { urls, location in
            // from the media library or the Finder: into the library, then onto this track
            let kind: MediaItem.Kind
            switch lane.kind {
            case .speaker: kind = .speech
            case .music: kind = .music
            case .effects: kind = .effect
            case .background: return false
            }
            Task { await state.dropOnTrack(urls, kind: kind, at: Double(location.x) / pps) }
            return true
        }
    }

    private func draw(clip: Lane.Clip, lane: Lane, in ctx: inout GraphicsContext, height: CGFloat) {
        let x = CGFloat(clip.at) * pps
        let w = max(1, CGFloat(clip.length) * pps)
        let rect = CGRect(x: x, y: 3, width: w, height: height - 6)
        let base = clip.generated ? Color.purple : color(lane.kind)
        let selected = (clip.userClip != nil && clip.userClip == selectedClip)
            || (clip.tokens != nil && clip.tokens == selectedVoice && clip.userClip == nil)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(base.opacity(selected ? 0.45 : 0.25)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(base.opacity(selected ? 1 : 0.6)), lineWidth: selected ? 2 : 1)

        // waveform: loudness of the clip's file, one bar per 2 px (taller when the clip is louder)
        let loud = CGFloat(pow(10, clip.gainDB / 40))
        if let wave = waves[clip.file.path], !wave.isEmpty {
            let mid = rect.midY
            var px = max(rect.minX, CGFloat(visible.lowerBound) * pps)
            let lastX = min(rect.maxX, CGFloat(visible.upperBound) * pps)
            while px < lastX {
                let t = clip.src + Double(px - rect.minX) / pps
                let i = Int(t * Waveform.peaksPerSecond)
                let level = i >= 0 && i < wave.count ? min(1, CGFloat(wave[i]) * loud) : 0
                let h = max(1, level * (rect.height - 6))
                ctx.fill(Path(CGRect(x: px, y: mid - h / 2, width: 1, height: h)), with: .color(base.opacity(0.85)))
                px += 2
            }
        }
        // fades of music and effects clips
        if clip.fadeIn > 0 {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX + CGFloat(clip.fadeIn) * pps, y: rect.minY))
            ctx.stroke(p, with: .color(.primary.opacity(0.7)), lineWidth: 1)
        }
        if clip.fadeOut > 0 {
            var p = Path()
            p.move(to: CGPoint(x: rect.maxX - CGFloat(clip.fadeOut) * pps, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.stroke(p, with: .color(.primary.opacity(0.7)), lineWidth: 1)
        }
        if let id = clip.userClip, w > 40,
           let name = (project.mix.music + project.mix.effects).first(where: { $0.id == id })?.name {
            ctx.draw(Text(name).font(.caption2).foregroundStyle(.primary), at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: .topLeading)
        }
        if clip.userClip == nil, clip.gainDB != 0, w > 36 {
            ctx.draw(Text("\(clip.gainDB > 0 ? "+" : "")\(Int(clip.gainDB.rounded())) дБ").font(.caption2.weight(.semibold)).foregroundStyle(.primary),
                     at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), anchor: .topLeading)
        }
    }

    private var overlay: some View {
        Canvas { ctx, size in
            if let selection {
                let rect = CGRect(x: CGFloat(selection.lowerBound) * pps, y: rulerHeight,
                                  width: CGFloat(selection.upperBound - selection.lowerBound) * pps, height: size.height)
                ctx.fill(Path(rect), with: .color(.accentColor.opacity(0.18)))
            }
            if let d = voiceDrag { drawGhost(d, in: &ctx) }
            if let d = drag, d.part == .body, case let target = targetLane(from: d.lane, dy: d.dy), target != d.lane,
               let c = (project.mix.music + project.mix.effects).first(where: { $0.id == d.id }) {
                let ok = lanes[target].kind == .music || lanes[target].kind == .effects
                let rect = CGRect(x: CGFloat(c.at + d.delta) * pps, y: rulerHeight + CGFloat(target) * laneHeight + 3,
                                  width: max(2, CGFloat(c.length) * pps), height: laneHeight - 6)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(ok ? .accentColor : .red),
                           style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                ctx.draw(Text(ok ? String(localized: "Перенести сюда") : String(localized: "Сюда нельзя: дорожки голоса связаны с текстом"))
                    .font(.caption.weight(.semibold)).foregroundStyle(ok ? Color.primary : Color.red),
                         at: CGPoint(x: rect.minX + 4, y: rect.minY - 2), anchor: .bottomLeading)
            }
            if tool == .razor, let h = hover {
                var line = Path()
                let hx = CGFloat(h.t) * pps
                line.move(to: CGPoint(x: hx, y: rulerHeight + CGFloat(h.lane) * laneHeight))
                line.addLine(to: CGPoint(x: hx, y: rulerHeight + CGFloat(h.lane + 1) * laneHeight))
                ctx.stroke(line, with: .color(.primary), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            let x = CGFloat(currentTime) * pps
            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1.5, height: size.height)), with: .color(.red))
            var head = Path()
            head.move(to: CGPoint(x: x - 5, y: 0)); head.addLine(to: CGPoint(x: x + 5, y: 0)); head.addLine(to: CGPoint(x: x, y: 7))
            ctx.fill(head, with: .color(.red))
        }
        .allowsHitTesting(false)
    }

    // MARK: Interaction

    /// Arrow: drag a clip to move it (a voice clip up or down — to another speaker), its
    /// edges to trim; drag on empty space selects a stretch; click selects and jumps there.
    /// Razor: click cuts the clip. Range: drag selects a stretch on any lane.
    private func laneGesture(_ lane: Lane, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let t0 = Double(v.startLocation.x) / pps, t1 = Double(v.location.x) / pps
                if gestureKind == nil {
                    takeKeyboard()
                    gestureKind = startGesture(lane, index: index, at: t0)
                }
                switch gestureKind {
                case .user:
                    drag?.delta = t1 - t0
                    drag?.dy = v.translation.height
                case .voice:
                    voiceDrag?.dx = t1 - t0
                    voiceDrag?.dy = v.translation.height
                case .range:
                    if abs(t1 - t0) * pps > 3 { selection = min(t0, t1)...max(t0, t1) }
                default:
                    break
                }
            }
            .onEnded { v in
                defer { gestureKind = nil }
                let t0 = Double(v.startLocation.x) / pps
                let moved = abs(v.translation.width) > 3 || abs(v.translation.height) > 3
                if tool == .razor {
                    razor(lane, at: t0)
                    return
                }
                if let d = drag {
                    commit(d)
                    drag = nil
                    return
                }
                if let d = voiceDrag {
                    voiceDrag = nil
                    if moved { commitVoice(d) } else { onSeek(max(0, t0)) }
                    return
                }
                if !moved {
                    selection = nil
                    onSeek(max(0, t0))
                }
            }
    }

    /// A click on the timeline takes the keyboard from the text above it, so Delete, V, C, R
    /// and ⌘K act on the timeline (the text gets it back when it is clicked).
    private func takeKeyboard() {
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.firstResponder is NSTextView }) {
            window.makeFirstResponder(nil)
        }
        focused = true
    }

    /// What a drag starting at time t on this lane will do.
    private func startGesture(_ lane: Lane, index: Int, at t: Double) -> GestureKind {
        switch tool {
        case .razor: return .none
        case .range: return .range
        case .select: break
        }
        if lane.kind == .music || lane.kind == .effects, let (clip, part) = hitClip(lane, at: t) {
            selectedClip = clip.id
            selectedVoice = nil
            drag = ClipDrag(id: clip.id, part: part, delta: 0, lane: index)
            return .user
        }
        if let (clip, part) = hitVoice(lane, at: t) {
            selectedVoice = clip.tokens
            selectedClip = nil
            selection = nil
            voiceDrag = VoiceDrag(clip: clip, lane: index, part: part, dx: 0, dy: 0)
            return .voice
        }
        selectedClip = nil
        selectedVoice = nil
        return .range
    }

    /// The voice clip under time t, and which part of it (an edge or the body).
    private func hitVoice(_ lane: Lane, at t: Double) -> (Lane.Clip, ClipDrag.Part)? {
        guard case .speaker = lane.kind else { return nil }
        let edge = 6 / pps
        for c in lane.clips where c.tokens != nil && t >= c.at - edge && t <= c.end + edge {
            let wide = c.length * pps > 20 && !c.generated      // re-voiced pieces only move
            if wide && abs(t - c.at) <= edge { return (c, .start) }
            if wide && abs(t - c.end) <= edge { return (c, .end) }
            if t >= c.at && t <= c.end { return (c, .body) }
        }
        return nil
    }

    /// The finished drag of a voice clip: to another speaker's lane, along the timeline, or an edge.
    private func commitVoice(_ d: VoiceDrag) {
        guard let tokens = d.clip.tokens else { return }
        switch d.part {
        case .body:
            let target = d.lane + Int((d.dy / laneHeight).rounded())
            if target != d.lane, lanes.indices.contains(target), case .speaker(let n) = lanes[target].kind {
                project.assignSpeaker(Array(tokens), to: n)
                selectedVoice = nil
            } else if target != d.lane, lanes.indices.contains(target), lanes[target].kind == .music || lanes[target].kind == .effects {
                // a laugh or a clap becomes its own sound: a clip on that lane, silence in the voice
                let clip = UserClip(file: d.clip.file.path, name: String(localized: "Кусок голоса"), at: max(0, d.clip.at + d.dx),
                                    inPoint: d.clip.src, length: d.clip.length,
                                    fileDuration: d.clip.src + d.clip.length + 60)
                project.extract(tokens, as: clip, toMusic: lanes[target].kind == .music)
                selectedVoice = nil
            } else if abs(d.dx) * pps > 2 {
                project.moveClip(tokens, by: d.dx)
            }
        case .start:
            project.trimClip(tokens, edge: .start, by: d.dx)
            selectedVoice = nil
        case .end:
            project.trimClip(tokens, edge: .end, by: d.dx)
            selectedVoice = nil
        }
    }

    /// Where a dragged voice clip would land, drawn over the lanes.
    private func drawGhost(_ d: VoiceDrag, in ctx: inout GraphicsContext) {
        let c = d.clip
        var lane = d.lane
        var a = c.at, b = c.end
        var label: String?
        switch d.part {
        case .body:
            let target = d.lane + Int((d.dy / laneHeight).rounded())
            if target != d.lane, lanes.indices.contains(target), case .speaker(let n) = lanes[target].kind {
                lane = target
                label = String(localized: "Это говорит: \(project.speakerName(n))")
            } else if target != d.lane, lanes.indices.contains(target), lanes[target].kind == .music || lanes[target].kind == .effects {
                lane = target
                a += d.dx
                b += d.dx
                label = String(localized: "Сделать отдельным звуком (в голосе останется тишина)")
            } else {
                a += d.dx
                b += d.dx
                if abs(d.dx) > 0.01 {
                    label = d.dx > 0 ? String(localized: "пауза длиннее на \(Format.seconds(d.dx)) с") : String(localized: "пауза короче на \(Format.seconds(-d.dx)) с")
                }
            }
        case .start:
            a = min(c.at + d.dx, c.end - 0.05)
            label = d.dx > 0 ? String(localized: "убрать начало") : String(localized: "вернуть начало")
        case .end:
            b = max(c.end + d.dx, c.at + 0.05)
            label = d.dx < 0 ? String(localized: "убрать конец") : String(localized: "вернуть конец")
        }
        let rect = CGRect(x: CGFloat(a) * pps, y: rulerHeight + CGFloat(lane) * laneHeight + 3,
                          width: max(2, CGFloat(b - a) * pps), height: laneHeight - 6)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.accentColor.opacity(0.15)))
        ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
        if let label {
            let text = Text(label).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            let p = CGPoint(x: rect.minX + 4, y: rect.minY - 2)
            let size = ctx.resolve(text).measure(in: CGSize(width: 400, height: 40))
            ctx.fill(Path(roundedRect: CGRect(x: p.x - 3, y: p.y - size.height, width: size.width + 6, height: size.height + 2),
                          cornerRadius: 3), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
            ctx.draw(text, at: p, anchor: .bottomLeading)
        }
    }

    /// Razor: cuts the clip under the click — a voice clip between the nearest two words.
    private func razor(_ lane: Lane, at t: Double) {
        if lane.kind == .music || lane.kind == .effects {
            if let (clip, _) = hitClip(lane, at: t), t > clip.at + 0.05, t < clip.end - 0.05 { splitUserClip(clip.id, at: t) }
            return
        }
        guard let (clip, _) = hitVoice(lane, at: t), let tokens = clip.tokens,
              let k = tokenBoundary(near: t), k > tokens.lowerBound, k <= tokens.upperBound else { return }
        project.split(before: k)
    }

    /// The token that starts closest to edited time t.
    private func tokenBoundary(near t: Double) -> Int? {
        guard let original = Timeline.originalTime(at: t, segments: project.segments),
              var k = Editing.tokenIndex(at: original, in: project.tokens) else { return nil }
        let token = project.tokens[k]
        if original - token.start > token.end - original, k + 1 < project.tokens.count { k += 1 }
        return k
    }

    /// ⌘K: cuts every clip under the playhead, like in Premiere.
    private func splitAtPlayhead() {
        let t = currentTime
        for c in project.mix.music + project.mix.effects where t > c.at + 0.05 && t < c.end - 0.05 {
            splitUserClip(c.id, at: t)
        }
        if let k = tokenBoundary(near: t), lanes.contains(where: { lane in
            lane.clips.contains { $0.tokens.map { k > $0.lowerBound && k <= $0.upperBound } ?? false }
        }) {
            project.split(before: k)
        }
    }

    private func splitUserClip(_ id: UUID, at t: Double) {
        project.changeMix { mix in
            func cut(_ list: inout [UserClip]) {
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                let c = list[i]
                var left = c, right = c
                left.length = t - c.at
                left.fadeOut = 0
                right.id = UUID()
                right.at = t
                right.inPoint = c.inPoint + (t - c.at)
                right.length = c.end - t
                right.fadeIn = 0
                left.fadeIn = min(left.fadeIn, left.length / 2)
                right.fadeOut = min(right.fadeOut, right.length / 2)
                list[i] = left
                list.insert(right, at: i + 1)
            }
            cut(&mix.music)
            cut(&mix.effects)
        }
    }

    /// The mouse pointer tells what a click or drag will do.
    private func cursor(_ lane: Lane, at t: Double) -> NSCursor {
        switch tool {
        case .razor: return .crosshair
        case .range: return .iBeam
        case .select: break
        }
        if lane.kind == .music || lane.kind == .effects, let (_, part) = hitClip(lane, at: t) {
            return part == .body ? .openHand : .resizeLeftRight
        }
        if let (_, part) = hitVoice(lane, at: t) {
            return part == .body ? .openHand : .resizeLeftRight
        }
        return .arrow
    }

    private func hitClip(_ lane: Lane, at t: Double) -> (UserClip, ClipDrag.Part)? {
        let clips = lane.kind == .music ? project.mix.music : project.mix.effects
        let edge = 7 / pps
        for c in clips.reversed() where t >= c.at - edge && t <= c.end + edge {
            if abs(t - c.at) <= edge { return (c, .start) }
            if abs(t - c.end) <= edge { return (c, .end) }
            return (c, .body)
        }
        return nil
    }

    /// A clip as it looks during a drag (not saved until the drag ends).
    private func shifted(_ clip: Lane.Clip) -> Lane.Clip {
        guard let d = drag, clip.userClip == d.id,
              let c = (project.mix.music + project.mix.effects).first(where: { $0.id == d.id }) else { return clip }
        let moved = apply(d, to: c)
        var out = clip
        out.at = moved.at
        out.src = moved.inPoint
        out.length = moved.length
        return out
    }

    private func apply(_ d: ClipDrag, to c: UserClip) -> UserClip {
        var c = c
        switch d.part {
        case .body:
            c.at = max(0, c.at + d.delta)
        case .start:   // trim the beginning: later start in the file, shorter clip
            let delta = min(max(d.delta, -c.inPoint), c.length - 0.1)
            c.at += delta
            c.inPoint += delta
            c.length -= delta
        case .end:
            c.length = min(max(0.1, c.length + d.delta), c.fileDuration - c.inPoint)
        }
        c.fadeIn = min(c.fadeIn, c.length / 2)
        c.fadeOut = min(c.fadeOut, c.length / 2)
        return c
    }

    private func commit(_ d: ClipDrag) {
        // a music or effects clip dropped on the other one of these two lanes moves there
        let target = targetLane(from: d.lane, dy: d.dy)
        if d.part == .body, target != d.lane, lanes[target].kind == .music || lanes[target].kind == .effects {
            let toMusic = lanes[target].kind == .music
            project.changeMix { mix in
                guard let clip = (mix.music + mix.effects).first(where: { $0.id == d.id }) else { return }
                var moved = apply(d, to: clip)
                moved.id = clip.id
                mix.music.removeAll { $0.id == d.id }
                mix.effects.removeAll { $0.id == d.id }
                if toMusic { mix.music.append(moved) } else { mix.effects.append(moved) }
            }
            return
        }
        guard abs(d.delta) > 0.001 else { return }
        project.changeMix { mix in
            if let i = mix.music.firstIndex(where: { $0.id == d.id }) { mix.music[i] = apply(d, to: mix.music[i]) }
            if let i = mix.effects.firstIndex(where: { $0.id == d.id }) { mix.effects[i] = apply(d, to: mix.effects[i]) }
        }
    }

    @ViewBuilder
    private func clipMenu(_ lane: Lane) -> some View {
        clipActions(lane)
        Divider()
        Section("Инструмент") {
            Toggle("Стрелка — двигать и подрезать (V)", isOn: Binding(get: { tool == .select }, set: { if $0 { tool = .select } }))
            Toggle("Лезвие — разрезать (C)", isOn: Binding(get: { tool == .razor }, set: { if $0 { tool = .razor } }))
            Toggle("Диапазон — выделить участок (R)", isOn: Binding(get: { tool == .range }, set: { if $0 { tool = .range } }))
        }
        Button("Разрезать под курсором (⌘K)") { splitAtPlayhead() }
        Menu("Масштаб") {
            Button("Крупнее (⌘+ или щипок)") { pps = min(256, pps * 1.5) }
            Button("Мельче (⌘− или щипок)") { pps = max(2, pps / 1.5) }
        }
    }

    @ViewBuilder
    private func clipActions(_ lane: Lane) -> some View {
        let t = hover?.t ?? currentTime
        if lane.kind == .music || lane.kind == .effects, let (clip, _) = hitClip(lane, at: t) {
            let id = clip.id
            Button("Плавное появление (1 с)") { editClip(id) { $0.fadeIn = $0.fadeIn > 0 ? 0 : min(1, $0.length / 2) } }
            Button("Плавное затухание (1 с)") { editClip(id) { $0.fadeOut = $0.fadeOut > 0 ? 0 : min(1, $0.length / 2) } }
            Menu("Громкость клипа") {
                ForEach([-12.0, -6, -3, 0, 3, 6], id: \.self) { v in
                    Button("\(v > 0 ? "+" : "")\(Int(v)) дБ") { editClip(id) { $0.gainDB = v } }
                }
            }
            Button("Разрезать здесь") { splitUserClip(id, at: t) }
                .disabled(t <= clip.at + 0.05 || t >= clip.end - 0.05)
            Divider()
            Button("Удалить клип", role: .destructive) { removeClip(id) }
        } else if lane.kind == .music || lane.kind == .effects {
            Button(lane.kind == .music ? String(localized: "Добавить музыку…") : String(localized: "Добавить звук…")) {
                addClip(to: lane.kind, at: lane.kind == .music ? 0 : t)
            }
        } else if let (clip, _) = hitVoice(lane, at: t), let tokens = clip.tokens {
            voiceMenu(clip, tokens: tokens, at: t)
        }
    }

    @ViewBuilder
    private func voiceMenu(_ clip: Lane.Clip, tokens: ClosedRange<Int>, at t: Double) -> some View {
        Button("Слушать отсюда") { onSeek(t) }
        Button("Разрезать здесь") {
            if let k = tokenBoundary(near: t), k > tokens.lowerBound, k <= tokens.upperBound { project.split(before: k) }
        }
        .disabled(clip.generated)
        Menu("Громкость куска") {
            ForEach([-12.0, -6, -3, 0, 3, 6, 12], id: \.self) { v in
                Button("\(v > 0 ? "+" : "")\(Int(v)) дБ\(v == 0 ? " (как записано)" : "")") { project.setGain(tokens, db: v) }
            }
        }
        if project.speakerCount > 1 {
            Menu("Это говорит") {
                ForEach(0..<project.speakerCount, id: \.self) { n in
                    Button(project.speakerName(n)) { project.assignSpeaker(Array(tokens), to: n) }
                }
            }
        }
        Button("Переозвучить…") { onRevoice(tokens) }
        let silence = project.insertedSilence(before: tokens)
        if silence > 0 {
            Button("Убрать вставленную тишину (\(Format.seconds(silence)) с)") { project.removeSilence(before: tokens) }
        }
        Divider()
        Button("Вырезать кусок", role: .destructive) {
            project.setState(Array(tokens), to: .delete)
            selectedVoice = nil
        }
    }

    private func editClip(_ id: UUID, _ change: @escaping (inout UserClip) -> Void) {
        project.changeMix { mix in
            if let i = mix.music.firstIndex(where: { $0.id == id }) { change(&mix.music[i]) }
            if let i = mix.effects.firstIndex(where: { $0.id == id }) { change(&mix.effects[i]) }
        }
    }

    private func removeClip(_ id: UUID) {
        project.changeMix { mix in
            mix.music.removeAll { $0.id == id }
            mix.effects.removeAll { $0.id == id }
        }
        selectedClip = nil
    }

    /// Delete: removes the selected clip, or cuts the selected stretch out of the recording
    /// (the words in it are deleted in the text too).
    private func deleteSelection() -> KeyPress.Result {
        if let id = selectedClip {
            removeClip(id)
            return .handled
        }
        if let tokens = selectedVoice {
            project.setState(Array(tokens), to: .delete)
            selectedVoice = nil
            return .handled
        }
        guard let selection else { return .ignored }
        let segments = project.segments
        var indices: [Int] = []
        for (i, t) in project.tokens.enumerated() where project.states[i] != .delete {
            guard let a = Timeline.editedTime(of: t.start, segments: segments) else { continue }
            let b = a + t.duration
            let inside = max(0, min(b, selection.upperBound) - max(a, selection.lowerBound))
            if inside >= t.duration * 0.5 { indices.append(i) }
        }
        if !indices.isEmpty { project.setState(indices, to: .delete) }
        self.selection = nil
        return .handled
    }

    private func addClip(to kind: Lane.Kind, at: Double) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppState.audioTypes
        panel.message = kind == .music ? String(localized: "Выберите музыку") : String(localized: "Выберите звук")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addClip(url, to: kind, at: at)
    }

    private func addClip(_ url: URL, to kind: Lane.Kind, at: Double) {
        Task {
            guard let audio = try? await Pipeline.audio(for: url),
                  let file = try? AVAudioFile(forReading: audio) else {
                state.errorMessage = String(localized: "Не получилось открыть «\(url.lastPathComponent)»")
                return
            }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let length = kind == .music ? min(duration, max(Timeline.duration(project.lanes) - at, 1)) : duration
            let clip = UserClip(file: audio.path, name: url.deletingPathExtension().lastPathComponent, at: max(0, at),
                                length: length, fileDuration: duration,
                                fadeIn: kind == .music ? min(1, length / 2) : 0,
                                fadeOut: kind == .music ? min(2, length / 2) : 0)
            project.changeMix { mix in
                if kind == .music { mix.music.append(clip) } else { mix.effects.append(clip) }
            }
            selectedClip = clip.id
        }
    }

    // MARK: Helpers

    private func followPlayhead() {
        guard state.player.isPlaying else { return }
        let width = visible.upperBound - visible.lowerBound
        if currentTime > visible.upperBound - width * 0.1 || currentTime < visible.lowerBound {
            scroll.scrollTo(x: CGFloat(max(0, currentTime - width * 0.1)) * pps)
        }
    }

    private func rulerStep() -> Double {
        let minPixels = 70.0
        for step in [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600] where step * pps >= minPixels { return step }
        return 1200
    }

    private func loadWaves() async {
        var files = Set(lanes.flatMap(\.clips).map(\.file))
        files.remove(project.sourceURL)
        if waves[project.sourceURL.path] == nil {
            waves[project.sourceURL.path] = await Waveform.load(source: project.sourceURL,
                                                                cache: project.folder.appendingPathComponent("loudness.bin"))
        }
        for file in files where waves[file.path] == nil {
            let name = "wave-\(Project.key(for: file)).bin"
            waves[file.path] = await Waveform.load(source: file, cache: project.folder.appendingPathComponent(name))
        }
    }

    private func title(_ kind: Lane.Kind) -> String {
        switch kind {
        case .speaker(let n): return project.speakerCount > 1 ? project.speakerName(n) : String(localized: "Голос")
        case .background: return String(localized: "Фон записи")
        case .music: return String(localized: "Музыка")
        case .effects: return String(localized: "Эффекты")
        }
    }

    private func color(_ kind: Lane.Kind) -> Color {
        switch kind {
        case .speaker(let n): return Color(nsColor: Style.speakerColor(n))
        case .background: return .gray
        case .music: return .green
        case .effects: return .orange
        }
    }
}
