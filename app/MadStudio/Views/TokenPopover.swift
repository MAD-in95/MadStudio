import SwiftUI

/// Small card shown when the mouse rests on a marker or a questionable word.
struct TokenPopover: View {
    let token: Token
    let state: TokenState
    var onSet: (TokenState) -> Void
    var onListen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { onListen() } label: { Label("Слушать", systemImage: "play.fill") }
                if state == .keep {
                    if token.kind == .pause && token.duration > 0.45 {
                        Button("Сократить") { onSet(.shorten) }
                    }
                    Button("Удалить", role: .destructive) { onSet(.delete) }
                        .keyboardShortcut(.delete, modifiers: [])
                } else {
                    Button("Оставить") { onSet(.keep) }
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    private var title: String {
        if token.take != nil { return String(localized: "Неудачный дубль") }
        let length = String(localized: "\(Format.seconds(token.duration)) с")
        switch token.kind {
        case .pause: return String(localized: "Пауза \(length)")
        case .breath: return String(localized: "Вдох \(length)")
        case .filler: return String(localized: "«Э-э» или мычание \(length)")
        case .click: return String(localized: "Щелчок")
        case .speech: return String(localized: "Речь, которой нет в тексте")
        case .word:
            if token.parasite == true { return String(localized: "Слово-паразит «\(token.text ?? "")»") }
            return "«\(token.text ?? "")»"
        }
    }

    private var detail: String? {
        if token.take != nil {
            return String(localized: "Эту фразу сразу сказали заново. Удалите первую попытку — останется удачная. Если повтор сделан нарочно, оставьте.")
        }
        switch token.kind {
        case .speech:
            return String(localized: "Повтор или реплика собеседника. Слышится примерно «\(token.text ?? "")».")
        case .word where (token.prob ?? 1) < 0.5:
            return String(localized: "Возможно, расслышано неточно — послушайте.")
        case .word where token.stretched == true:
            return String(localized: "Слово звучит дольше обычного — внутри может быть «э-э» или пауза.")
        default:
            return nil
        }
    }
}

/// Card for a re-voiced piece.
struct GeneratedPopover: View {
    let replacement: Replacement
    let original: String
    var onRestore: () -> Void
    var onListen: () -> Void
    var onTempo: (Double) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Сгенерировано голосом ИИ", systemImage: "waveform.badge.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.purple)
            Text("Было: «\(original)»").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { onListen() } label: { Label("Слушать", systemImage: "play.fill") }
                Button("Вернуть как было") { onRestore() }
            }
            HStack(spacing: 8) {
                Text("Темп\((replacement.speed ?? 1) == 1 ? "" : " ×" + Format.seconds(replacement.speed ?? 1)):")
                    .foregroundStyle(.secondary)
                Button { onTempo(1 / 1.1) } label: { Label("Медленнее", systemImage: "tortoise") }
                    .help("Сделать этот кусок на 10% медленнее, голос не меняется")
                Button { onTempo(1.1) } label: { Label("Быстрее", systemImage: "hare") }
                    .help("Сделать этот кусок на 10% быстрее, голос не меняется")
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}
