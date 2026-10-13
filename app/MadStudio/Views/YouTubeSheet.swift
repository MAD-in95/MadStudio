import AppKit
import SwiftUI

/// What the language model suggested for YouTube; everything can be copied.
struct YouTubeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kit: AppState.YouTubeKit

    private var chaptersText: String {
        kit.chapters.map { "\($0.stamp) \($0.title)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Для YouTube").font(.title2.bold())
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    block(String(localized: "Главы (вставьте в описание видео)"), text: chaptersText)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Варианты названия").font(.headline)
                        ForEach(kit.titles, id: \.self) { title in
                            HStack {
                                Text(title).textSelection(.enabled)
                                Spacer()
                                copy(title)
                            }
                        }
                    }
                    block(String(localized: "Описание"), text: kit.description)
                    block(String(localized: "Теги"), text: kit.tags.joined(separator: ", "))
                    Text("Таймкоды — по смонтированной записи. Тексты написала нейросеть на этом Mac: проверьте перед публикацией.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
        .frame(width: 560, height: 600)
    }

    private func block(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                copy(text)
            }
            Text(text.isEmpty ? "—" : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func copy(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Label("Копировать", systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
    }
}
