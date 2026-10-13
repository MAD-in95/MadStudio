import SwiftUI

/// ⌘F over the transcript: find a word or a phrase, step through the places, cut them all.
struct SearchBar: View {
    @Binding var query: String
    let count: Int
    @Binding var current: Int
    /// true when every found place is already cut (the button then brings them back)
    let allCut: Bool
    var onCutAll: () -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.Colors.muted)
            TextField("Найти в тексте", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 220)
                .onSubmit { step(1) }
            Text(query.isEmpty ? "" : count == 0 ? String(localized: "не найдено") : String(localized: "\(current + 1) из \(count)"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(count == 0 && !query.isEmpty ? Theme.Colors.accent : Theme.Colors.muted)
                .frame(minWidth: 70, alignment: .trailing)
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help("Предыдущее (⇧↩)")
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(count == 0)
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help("Следующее (↩)")
                .disabled(count == 0)
            Button(allCut ? String(localized: "Вернуть все") : String(localized: "Вырезать все")) { onCutAll() }
                .help("Вырезать из записи все найденные места сразу (⌘Z — вернуть)")
                .disabled(count == 0)
            Button { onClose() } label: { Image(systemName: "xmark") }
                .help("Закрыть поиск (Esc)")
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Colors.panel2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.lineStrong))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .onAppear { focused = true }
        .onChange(of: query) { current = 0 }
    }

    private func step(_ delta: Int) {
        guard count > 0 else { return }
        current = (current + delta + count) % count
    }
}
