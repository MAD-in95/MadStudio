import SwiftUI

/// MadStudio → Settings (⌘,): the interface language.
struct SettingsView: View {
    @State private var language = AppLanguage.chosen
    private let started = AppLanguage.chosen

    var body: some View {
        Form {
            Picker("Язык интерфейса", selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: language) { AppLanguage.chosen = language }
            if language != started {
                HStack {
                    Text("Язык сменится после перезапуска программы.")
                        .foregroundStyle(Theme.Colors.muted)
                    Spacer()
                    Button("Перезапустить") { AppLanguage.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460, height: 150)
        .preferredColorScheme(.dark)
    }
}
