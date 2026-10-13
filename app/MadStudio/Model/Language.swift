import AppKit
import Foundation

/// The interface language. Follows macOS unless chosen in Settings; a change takes effect after
/// the program restarts (macOS picks the language when a program starts).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Как в macOS")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }

    private static let key = "interfaceLanguage"

    static var chosen: AppLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// the language the program is showing right now
    static var current: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var isEnglish: Bool { current == "en" }
    /// dates and numbers written the way this language writes them
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "ru_RU") }

    /// Starts the program again (to show the newly chosen language).
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
