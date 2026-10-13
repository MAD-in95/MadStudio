import Foundation

enum Format {
    /// 83.4 -> "1:23", 3725 -> "1:02:05"
    static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// How long something will take: "≈25 с", "≈3 мин", "≈1 ч 10 мин".
    static func duration(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return String(localized: "≈\(s) с") }
        let m = Int((Double(s) / 60).rounded())
        return m < 60 ? String(localized: "≈\(m) мин") : String(localized: "≈\(m / 60) ч") + (m % 60 > 0 ? String(localized: " \(m % 60) мин") : "")
    }

    /// 0.84 -> "0,8" (in English "0.8")
    static func seconds(_ value: Double) -> String {
        decimal(value, digits: 1)
    }

    /// A fractional number with the decimal mark of the interface language.
    static func decimal(_ value: Double, digits: Int) -> String {
        let text = String(format: "%.\(digits)f", value)
        return AppLanguage.isEnglish ? text : text.replacingOccurrences(of: ".", with: ",")
    }
}
