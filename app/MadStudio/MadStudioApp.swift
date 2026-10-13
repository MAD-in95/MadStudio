import SwiftUI
import UniformTypeIdentifiers

@main
struct MadStudioApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("MadStudio") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)       // the «Студия» look is dark
                .tint(Theme.Colors.accent)
                .onAppear { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Модели нейросетей…") { state.showModels = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Подтверждённые голоса…") { state.showVoices = true }
                Button("Настройки микрофона…") { state.showMicSettings = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Новый проект") { state.newProject() }
                    .keyboardShortcut("n")
                Button("Открыть запись…") { state.chooseFile() }
                    .keyboardShortcut("o")
                Button("Записать голос…") { state.studio == nil ? state.recordNewProject() : (state.showRecorder = true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Добавить в медиатеку…") { state.chooseMedia() }
                    .keyboardShortcut("i")
                    .disabled(state.studio == nil)
                Button("Пакетная обработка…") { state.showBatch = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить") { state.project?.undo() }
                    .keyboardShortcut("z")
                    .disabled(!(state.project?.canUndo ?? false))
                Button("Повторить") { state.project?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(state.project?.canRedo ?? false))
            }
            CommandGroup(after: .importExport) {
                Button("Экспорт в MP3…") { state.export(as: .mp3) }
                    .keyboardShortcut("e")
                    .disabled(state.project == nil)
                Button("Экспорт в WAV…") { state.export(as: .wav) }
                    .disabled(state.project == nil)
                Button("Субтитры SRT…") { state.exportSubtitles(vtt: false) }
                    .disabled(state.project == nil)
                Button("Субтитры VTT…") { state.exportSubtitles(vtt: true) }
                    .disabled(state.project == nil)
                Button("Текст…") { state.exportText(timecodes: false) }
                    .disabled(state.project == nil)
                Divider()
                Button("Озвучить текст…") { state.showSpeak = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Проверить файл на метку ИИ…") { state.checkWatermark() }
            }
        }
        Settings {
            SettingsView()
        }
    }
}
