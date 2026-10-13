import AppKit
import SwiftUI

/// The transcript shown as a document. Each token (word, pause, breath…) is a piece of
/// text; deleting text cuts the matching audio. Built on NSTextView for speed with long texts.
struct TranscriptView: NSViewRepresentable {
    let project: Project
    let revision: Int
    /// font and size of the text: a change rebuilds it
    var textStyle = ""
    let currentTime: Double
    let isPlaying: Bool
    var onClickToken: (Int) -> Void
    var onToggleDelete: ([Int]) -> Void
    var onSetState: ([Int], TokenState) -> Void
    var onSpace: () -> Void
    var onSelect: ([Int]) -> Void = { _ in }
    var onRestore: (UUID) -> Void = { _ in }
    var onTempo: (UUID, Double) -> Void = { _, _ in }
    var onPlayToken: (Int) -> Void = { _ in }
    var onRevoice: () -> Void = {}
    var onTool: (String) -> Void = { _ in }
    var onAssignSpeaker: ([Int], Int) -> Void = { _, _ in }
    /// found by ⌘F: all places, and the one shown now
    var searchMatches: [ClosedRange<Int>] = []
    var currentMatch: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let textView = TokenTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.bg
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor: Theme.rgb(0xFF5A1F, alpha: 0.35)]
        textView.textContainerInset = NSSize(width: 48, height: 32)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        textView.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let textView = c.textView else { return }
        textView.onClick = { [c] index in
            if let token = c.token(atCharacter: index) { onClickToken(token) }
        }
        textView.onDelete = { [c, weak textView] in
            guard let textView else { return }
            let tokens = c.tokens(in: textView.selectedRange())
            onToggleDelete(tokens)
            textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        }
        textView.onSpace = onSpace
        textView.wordRange = { [c] index in c.token(atCharacter: index).map { c.range(of: $0) } }
        textView.onPlayFrom = { [c] index in if let t = c.token(atCharacter: index) { onPlayToken(t) } }
        textView.onRevoice = onRevoice
        textView.onTool = onTool
        textView.selectionIsDeleted = { [c, weak textView] in
            guard let textView else { return false }
            let t = c.tokens(in: textView.selectedRange())
            return !t.isEmpty && t.allSatisfy { project.states[$0] != .keep }
        }
        c.onSelect = onSelect
        c.onRestore = onRestore
        c.onTempo = onTempo
        textView.speakers = project.speakerCount > 1
            ? (0..<project.speakerCount).map { project.speakerName($0) } : []
        textView.onAssignSpeaker = { [c, weak textView] speaker in
            guard let textView else { return }
            let indices = c.tokens(in: textView.selectedRange())
            if !indices.isEmpty { onAssignSpeaker(indices, speaker) }
        }
        if c.demoObserver == nil, CommandLine.arguments.contains("--demo") {
            c.demoObserver = NotificationCenter.default.addObserver(forName: .madStudioDemoHover, object: nil, queue: .main) { [c, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let textView, let index = project.tokens.firstIndex(where: { $0.kind == .breath }) else { return }
                    textView.scrollRangeToVisible(c.range(of: index))
                    c.hover(character: c.range(of: index).location, in: textView, project: project,
                            onSet: { i, state in onSetState([i], state) }, onListen: { onClickToken($0) })
                }
            }
        }
        textView.onHover = { [c, weak textView] index in
            guard let textView else { return }
            c.hover(character: index, in: textView, project: project,
                    onSet: { i, state in onSetState([i], state) },
                    onListen: { onClickToken($0) })
        }

        if c.revision != revision || c.projectID != ObjectIdentifier(project) || c.textStyle != textStyle {
            let firstBuild = c.projectID != ObjectIdentifier(project)
            c.projectID = ObjectIdentifier(project)
            c.revision = revision
            c.textStyle = textStyle
            c.rebuild(project: project)
            if firstBuild { textView.scroll(.zero) }
        }
        c.showSearch(searchMatches, current: currentMatch)
        c.highlight(time: currentTime, follow: isPlaying, tokens: project.tokens)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: TokenTextView?
        var onSelect: ([Int]) -> Void = { _ in }
        var onRestore: (UUID) -> Void = { _ in }
        var onTempo: (UUID, Double) -> Void = { _, _ in }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            onSelect(tokens(in: textView.selectedRange()))
        }
        var revision = -1
        var textStyle = ""
        var projectID: ObjectIdentifier?
        private var ranges: [NSRange] = []
        private var highlighted: Int?

        func rebuild(project: Project) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = NSMutableAttributedString()
            ranges = []
            ranges.reserveCapacity(project.tokens.count)
            var hasWords = false
            var labelled: Int?
            let showSpeakers = project.speakerCount > 1
            let starting = Dictionary(project.replacements.map { ($0.first, $0) }, uniquingKeysWith: { a, _ in a })
            var skipUntil = -1
            for (i, token) in project.tokens.enumerated() {
                if i <= skipUntil {
                    ranges.append(ranges[ranges.count - 1])  // tokens inside a re-voiced piece
                    continue
                }
                if let r = starting[i] {
                    if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: Style.word)) }
                    let piece = Style.generated(r, original: project.tokens[r.first...r.last])
                    ranges.append(NSRange(location: text.length, length: piece.length))
                    text.append(piece)
                    skipUntil = r.last
                    hasWords = true
                    continue
                }
                if token.isWord, token.text?.isEmpty == true {
                    // a word removed by a text correction: nothing to show, the sound stays
                    ranges.append(NSRange(location: text.length, length: 0))
                    continue
                }
                let speakerChanges = showSpeakers && token.isWord && token.speaker != nil
                    && labelled != nil && token.speaker != labelled
                if text.length > 0 {
                    let newParagraph = (token.para == true || speakerChanges) && hasWords
                    let separator = newParagraph ? "\n\n" : (Style.attaches(token) ? "" : " ")
                    text.append(NSAttributedString(string: separator, attributes: Style.word))
                }
                // speaker name at the start of each of their turns
                if showSpeakers, token.isWord, let speaker = token.speaker, speaker != labelled {
                    text.append(Style.speakerLabel(project.speakerName(speaker), id: speaker))
                    labelled = speaker
                }
                let piece = Style.piece(for: token, state: project.states[i])
                ranges.append(NSRange(location: text.length, length: piece.length))
                text.append(piece)
                hasWords = hasWords || token.isWord
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            storage.setAttributedString(text)
            highlighted = nil
            searchKey = nil   // the text was rebuilt: paint the search results again
        }

        // MARK: Search (⌘F)

        private var searchKey: String?
        private var searchRanges: [NSRange] = []
        private var currentSearch: NSRange?

        private func characters(of match: ClosedRange<Int>) -> NSRange? {
            guard match.upperBound < ranges.count else { return nil }
            return NSUnionRange(ranges[match.lowerBound], ranges[match.upperBound])
        }

        /// Marks every match in the text and scrolls to the current one.
        func showSearch(_ matches: [ClosedRange<Int>], current: Int?) {
            let key = "\(matches.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ","))|\(current ?? -1)"
            guard key != searchKey, let textView, let layout = textView.layoutManager else { return }
            searchKey = key
            for r in searchRanges { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r) }
            searchRanges = matches.compactMap(characters(of:))
            currentSearch = current.flatMap { $0 < matches.count ? characters(of: matches[$0]) : nil }
            for r in searchRanges { paintSearch(r, in: layout) }
            if let currentSearch {
                textView.scrollRangeToVisible(currentSearch)
                textView.showFindIndicator(for: currentSearch)
            }
        }

        private func paintSearch(_ range: NSRange, in layout: NSLayoutManager) {
            let color = range == currentSearch ? Style.searchCurrent : Style.searchFound
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }

        var demoObserver: NSObjectProtocol?
        func range(of token: Int) -> NSRange { ranges[token] }

        private var hoverTimer: Timer?
        private var hovered: Int?
        private let popover: NSPopover = {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            return p
        }()

        /// Shows the action card after the mouse rests on a marker or a questionable word.
        func hover(character: Int?, in textView: NSTextView, project: Project,
                   onSet: @escaping (Int, TokenState) -> Void, onListen: @escaping (Int) -> Void) {
            let index = character.flatMap { token(atCharacter: $0) }
            guard index != hovered else { return }
            hovered = index
            hoverTimer?.invalidate()
            guard let index, Self.hasActions(project.tokens[index]) || project.replacement(covering: index) != nil else { return }
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView, self.hovered == index else { return }
                    self.showPopover(for: index, in: textView, project: project, onSet: onSet, onListen: onListen)
                }
            }
        }

        private func showPopover(for index: Int, in textView: NSTextView, project: Project,
                                 onSet: @escaping (Int, TokenState) -> Void, onListen: @escaping (Int) -> Void) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            let glyphs = layout.glyphRange(forCharacterRange: ranges[index], actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            if let r = project.replacement(covering: index) {
                let view = GeneratedPopover(
                    replacement: r,
                    original: project.tokens[r.first...r.last].filter(\.isWord).compactMap(\.text).joined(separator: " "),
                    onRestore: { [weak self] in
                        self?.onRestore(r.id)
                        self?.popover.performClose(nil)
                    },
                    onListen: { onListen(r.first) },
                    onTempo: { [weak self] factor in
                        self?.onTempo(r.id, factor)
                        self?.popover.performClose(nil)
                    })
                popover.contentViewController = NSHostingController(rootView: view)
            } else {
                let view = TokenPopover(
                    token: project.tokens[index],
                    state: project.states[index],
                    onSet: { [weak self] state in
                        onSet(index, state)
                        self?.popover.performClose(nil)
                    },
                    onListen: { onListen(index) })
                popover.contentViewController = NSHostingController(rootView: view)
            }
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }

        static func hasActions(_ token: Token) -> Bool {
            if token.kind != .word || token.take != nil { return true }
            return token.parasite == true || token.stretched == true || (token.prob ?? 1) < 0.5
        }

        func token(atCharacter index: Int) -> Int? {
            // ranges are sorted: binary search for the last range starting at or before index
            var lo = 0, hi = ranges.count - 1
            guard hi >= 0 else { return nil }
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if ranges[mid].location <= index { lo = mid } else { hi = mid - 1 }
            }
            return NSLocationInRange(index, ranges[lo]) ? lo : nil
        }

        func tokens(in selection: NSRange) -> [Int] {
            guard selection.length > 0 else { return [] }
            return ranges.indices.filter { NSIntersectionRange(ranges[$0], selection).length > 0 }
        }

        func highlight(time: Double, follow: Bool, tokens: [Token]) {
            guard let textView, let layout = textView.layoutManager else { return }
            let index = Editing.tokenIndex(at: time, in: tokens)
            guard index != highlighted else { return }
            if let old = highlighted, old < ranges.count {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: ranges[old])
                // a search result under the word that just stopped playing stays marked
                for r in searchRanges where NSIntersectionRange(r, ranges[old]).length > 0 { paintSearch(r, in: layout) }
            }
            highlighted = index
            if let index, index < ranges.count {
                layout.addTemporaryAttribute(.backgroundColor, value: Style.playing, forCharacterRange: ranges[index])
                if follow { textView.scrollRangeToVisible(ranges[index]) }
            }
        }
    }
}

final class TokenTextView: NSTextView {
    var onClick: ((Int) -> Void)?
    var speakers: [String] = []
    var onAssignSpeaker: ((Int) -> Void)?

    /// what a right click / two-finger click works on: the word under the pointer (when
    /// nothing is selected) — given a character, returns that word's character range
    var wordRange: ((Int) -> NSRange?)?
    var onPlayFrom: ((Int) -> Void)?
    var onRevoice: (() -> Void)?
    var onTool: ((String) -> Void)?
    var selectionIsDeleted: (() -> Bool)?

    /// Right click (two-finger click on the trackpad): the program's own tools instead of the
    /// system text menu, with their keys shown — so the keys can be learned on the way.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(at: point)
        if selectedRange().length == 0, let index, let r = wordRange?(index) {
            setSelectedRange(r)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
                 _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, key: key, action: action)
            item.keyEquivalentModifierMask = modifiers
            item.isEnabled = enabled
            menu.addItem(item)
        }
        let hasWords = selectedRange().length > 0
        if let index {
            add(String(localized: "Слушать отсюда   (курсор + пробел)")) { [weak self] in self?.onPlayFrom?(index) }
        }
        if hasWords {
            let deleted = selectionIsDeleted?() ?? false
            add(deleted ? String(localized: "Вернуть") : String(localized: "Вырезать"), "\u{8}") { [weak self] in self?.onDelete?() }
            add(String(localized: "Переозвучить…"), "r", .command) { [weak self] in self?.onRevoice?() }
            add(String(localized: "Исправить текст (звук не меняется)…")) { [weak self] in self?.onTool?("correct") }
            if !speakers.isEmpty {
                let sub = NSMenu()
                for (i, name) in speakers.enumerated() {
                    let item = NSMenuItem(title: name, action: #selector(assignSpeaker(_:)), keyEquivalent: "")
                    item.tag = i
                    item.target = self
                    sub.addItem(item)
                }
                let root = NSMenuItem(title: String(localized: "Это говорит"), action: nil, keyEquivalent: "")
                root.submenu = sub
                menu.addItem(root)
            }
            add(String(localized: "Копировать текст"), "c", .command) { [weak self] in self?.copy(nil) }
        }
        add(String(localized: "Найти в тексте…"), "f", .command) { [weak self] in self?.onTool?("find") }
        menu.addItem(.separator())
        add(String(localized: "Почистить автоматически")) { [weak self] in self?.onTool?("clean") }
        add(String(localized: "Статистика речи")) { [weak self] in self?.onTool?("stats") }
        add(String(localized: "Найти моменты для Shorts")) { [weak self] in self?.onTool?("shorts") }
        menu.addItem(.separator())
        add(String(localized: "Записать голос…"), "r", [.command, .shift]) { [weak self] in self?.onTool?("record") }
        add(String(localized: "Озвучить текст…"), "t", [.command, .shift]) { [weak self] in self?.onTool?("speak") }
        add(String(localized: "Размер и шрифт текста — кнопка «Aa» справа вверху"), enabled: false) {}
        return menu
    }

    @objc private func assignSpeaker(_ sender: NSMenuItem) {
        onAssignSpeaker?(sender.tag)
    }
    var onHover: ((Int?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(characterIndex(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    /// Character under a point, or nil when the point is not over text.
    func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(p) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
    var onDelete: (() -> Void)?
    var onSpace: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)  // tracks the drag until the mouse is released
        guard event.clickCount == 1, selectedRange().length == 0,
              let index = characterIndex(at: point) else { return }
        onClick?(index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:  // Delete, Forward Delete
            onDelete?()
        case 49:       // Space
            onSpace?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// Colours from the plan: gray — pauses, blue — breaths and clicks, yellow — unclear words.
enum Style {
    /// The text's font and size, chosen by the person (the «Aa» button above the text).
    static var fontSize: CGFloat {
        let v = UserDefaults.standard.double(forKey: "textFontSize")
        return v > 0 ? CGFloat(v) : 17
    }
    static var fontName: String { UserDefaults.standard.string(forKey: "textFontName") ?? "" }
    static var font: NSFont {
        (fontName.isEmpty ? nil : NSFont(name: fontName, size: fontSize)) ?? NSFont.systemFont(ofSize: fontSize)
    }
    static var markerFont: NSFont { NSFont.systemFont(ofSize: max(10, fontSize * 0.7), weight: .medium) }
    static var word: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: Theme.text] }
    static let playing = Theme.rgb(0xFF5A1F, alpha: 0.3)
    static let searchFound = Theme.rgb(0x4EA1FF, alpha: 0.28)
    static let searchCurrent = Theme.rgb(0x4EA1FF, alpha: 0.65)
    static let pauseColor = Theme.rgb(0x8D8A96)
    static let soundColor = Theme.rgb(0x6FD4E0)
    static let unclearColor = Theme.rgb(0xE8C547)
    static let takeColor = Theme.rgb(0xF08A3C)
    static let speakerColors: [NSColor] = [0x4EA1FF, 0xFF6F91, 0x3FBF6F, 0xF0A020, 0x6FD4E0, 0xA98BFF].map { Theme.rgb($0) }

    static func speakerColor(_ id: Int) -> NSColor { speakerColors[id % speakerColors.count] }

    static func speakerLabel(_ name: String, id: Int) -> NSAttributedString {
        NSAttributedString(string: "\(name):  ", attributes: [
            .font: NSFont.systemFont(ofSize: max(11, fontSize * 0.88), weight: .semibold),
            .foregroundColor: speakerColor(id),
        ])
    }
    static let generatedColor = Theme.rgb(0xA98BFF)

    static func generated(_ r: Replacement, original: ArraySlice<Token>) -> NSAttributedString {
        let was = original.filter(\.isWord).compactMap(\.text).joined(separator: " ")
        return NSAttributedString(string: r.text, attributes: [
            .font: font,
            .foregroundColor: Theme.text,
            .backgroundColor: generatedColor.withAlphaComponent(0.28),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: generatedColor,
            .toolTip: String(localized: "Сгенерировано голосом ИИ вместо «\(was)»"),
        ])
    }

    /// Shorter pauses are shown as a dot to keep the text readable.
    static let shortPause = 0.5

    /// Word pieces like "-то" or a lone "…" stick to the previous word without a space.
    static func attaches(_ token: Token) -> Bool {
        guard token.isWord, let first = token.text?.first else { return false }
        return "-.,!?…:;)»".contains(first)
    }

    static func piece(for token: Token, state: TokenState) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any]
        let label: String
        switch token.kind {
        case .word:
            label = token.text ?? ""
            attrs = word
            if token.parasite == true {
                attrs[.backgroundColor] = soundColor.withAlphaComponent(0.25)
                attrs[.toolTip] = String(localized: "Слово-паразит. Delete — удалить")
            } else if (token.prob ?? 1) < 0.5 {
                attrs[.backgroundColor] = unclearColor.withAlphaComponent(0.35)
                attrs[.toolTip] = String(localized: "Возможно, расслышано неточно")
            } else if token.stretched == true {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attrs[.underlineColor] = soundColor
                attrs[.toolTip] = String(localized: "Слово звучит дольше обычного — возможно, внутри «э-э» или пауза")
            }
        case .pause:
            if token.duration < shortPause {
                label = "·"
            } else {
                let length = state == .shorten
                    ? "\(Format.seconds(token.duration)) → \(Format.seconds(0.4))"
                    : Format.seconds(token.duration)
                label = String(localized: "⏸ \(length) с")
            }
            attrs = marker(pauseColor)
            attrs[.toolTip] = String(localized: "Пауза \(Format.seconds(token.duration)) с. Delete — удалить")
        case .breath:
            label = String(localized: "вдох")
            attrs = marker(soundColor)
            attrs[.toolTip] = String(localized: "Вдох \(Format.seconds(token.duration)) с. Delete — удалить")
        case .filler:
            label = String(localized: "э-э")
            attrs = marker(soundColor)
            attrs[.toolTip] = String(localized: "Мычание или «э-э» \(Format.seconds(token.duration)) с. Delete — удалить")
        case .click:
            label = String(localized: "щелчок")
            attrs = marker(soundColor)
            attrs[.toolTip] = String(localized: "Щелчок. Delete — удалить")
        case .speech:
            label = "≈\(token.text ?? "…")"
            attrs = [
                .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                .foregroundColor: Theme.muted,
            ]
            attrs[.toolTip] = String(localized: "Здесь звучит речь, которой нет в тексте: повтор или реплика собеседника. ")
                + String(localized: "Слышится примерно «\(token.text ?? "")». Автоматически не удаляется.")
        }
        if token.take != nil {
            attrs[.backgroundColor] = takeColor.withAlphaComponent(0.28)
            attrs[.toolTip] = String(localized: "Неудачный дубль: эту фразу сразу сказали заново. Delete — удалить")
        }
        if state == .delete {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = Theme.rgb(0x5E5B66)
            attrs[.backgroundColor] = nil
        }
        return NSAttributedString(string: label, attributes: attrs)
    }

    private static func marker(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: markerFont,
            .foregroundColor: color,
            .backgroundColor: color.withAlphaComponent(0.14),
            .baselineOffset: 2,
        ]
    }
}

extension Notification.Name {
    static let madStudioDemoHover = Notification.Name("madStudioDemoHover")
    /// developer check: select Shorts moment number `object` (Int) on the timeline
    static let madStudioDemoSelectShort = Notification.Name("madStudioDemoSelectShort")
    /// developer check: open the voice confirmation for speaker 0
    static let madStudioDemoConfirmVoice = Notification.Name("madStudioDemoConfirmVoice")
    /// developer check: open «Переозвучить» for words `object` (ClosedRange<Int>)
    static let madStudioDemoRevoice = Notification.Name("madStudioDemoRevoice")
}

/// A menu item that runs a closure (for menus built in code).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, key: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
