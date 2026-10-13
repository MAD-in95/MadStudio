import AppKit
import SwiftUI

/// The «Студия» look chosen by the author: graphite panels, fire-orange for the main things
/// (the «Почистить» button, the playhead, selection). Colours in one place.
enum Theme {
    static let bg = rgb(0x16161A)          // text document, window
    static let panel = rgb(0x1D1D22)       // side panels, title bar
    static let panel2 = rgb(0x26262D)      // fields, buttons, thumbnails
    static let line = rgb(0x2F2F37)
    static let lineStrong = rgb(0x4A4A55)
    static let text = rgb(0xE8E6EA)
    static let muted = rgb(0x8D8A96)
    static let accent = rgb(0xFF5A1F)      // fire orange from the emblem
    static let timeline = rgb(0x131317)
    static let selection = rgb(0x2B2420)

    static var color: Colors.Type { Colors.self }

    /// The same colours for SwiftUI.
    enum Colors {
        static let bg = Color(nsColor: Theme.bg)
        static let panel = Color(nsColor: Theme.panel)
        static let panel2 = Color(nsColor: Theme.panel2)
        static let line = Color(nsColor: Theme.line)
        static let lineStrong = Color(nsColor: Theme.lineStrong)
        static let text = Color(nsColor: Theme.text)
        static let muted = Color(nsColor: Theme.muted)
        static let accent = Color(nsColor: Theme.accent)
        static let timeline = Color(nsColor: Theme.timeline)
        static let selection = Color(nsColor: Theme.selection)
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    /// Panel headings: small, uppercase, spaced out — as in the «Студия» sketch.
    func panelHeader() -> some View {
        font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(Theme.Colors.muted)
    }
}
