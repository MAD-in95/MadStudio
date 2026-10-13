import SwiftUI

/// «Исправить текст»: change what the transcript says (a misheard word, a name) without
/// touching the sound — for subtitles, the text export and chapters.
struct CorrectTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    var onSave: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Исправить текст").font(.title3.bold())
            Text("Звук не меняется — исправляется только написание: для субтитров, текста и глав. Чтобы слова прозвучали иначе, нужна «Переозвучка» (⌘R).")
                .font(.callout).foregroundStyle(Theme.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Текст", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .lineLimit(1...4)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Исправить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces) == original)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear { text = original }
    }

    private func save() {
        onSave(text)
        dismiss()
    }
}
