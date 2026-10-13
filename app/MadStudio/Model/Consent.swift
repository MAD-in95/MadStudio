import Foundation

/// A voice whose owner confirmed it by reading a random phrase aloud. Kept for all projects:
/// the same voice in another recording is recognised and needs no new confirmation.
struct VoiceProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// voice prints: the voice in the recording and in the reading
    var prints: [[Double]]
    var confirmed = Date()
    var phrase: String
}

/// Why the program may speak in a speaker's voice in this project.
enum VoiceConsent: Codable, Equatable {
    /// the person read the phrase aloud (a voice from the library)
    case confirmed(UUID)
    /// the author confirmed they have the guest's consent
    case guest
}

enum VoiceLibrary {
    /// One person through a phone, a room or a laptop mic: 0.76–0.87; different people 0.15–0.35.
    static let sameVoice = 0.5
    /// a voice recognised this surely in a new recording is remembered from there too:
    /// the more mics and moods the program has heard, the surer it recognises the voice
    static let learn = 0.6
    static let maxPrints = 8

    /// The voice with one more print (if it adds something new); the two prints of the
    /// confirmation itself are always kept.
    static func learning(_ print: [Double], into voice: VoiceProfile) -> VoiceProfile {
        guard (voice.prints.map { cosine($0, print) }.max() ?? 0) < 0.97 else { return voice }
        var v = voice
        v.prints.append(print)
        if v.prints.count > maxPrints { v.prints.remove(at: 2) }
        return v
    }

    static var url: URL { AppPaths.home.appendingPathComponent("voices.json") }
    private static var ids: Set<UUID>?

    static func load() -> [VoiceProfile] {
        let voices = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([VoiceProfile].self, from: $0) } ?? []
        ids = Set(voices.map(\.id))
        return voices
    }

    static func save(_ voices: [VoiceProfile]) {
        if let data = try? JSONEncoder().encode(voices) { try? data.write(to: url) }
        ids = Set(voices.map(\.id))
    }

    /// Is this voice still confirmed? (A voice removed from the list is not, in any project.)
    static func contains(_ id: UUID) -> Bool {
        if ids == nil { _ = load() }
        return ids?.contains(id) ?? false
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / max(sqrt(na * nb), 1e-12)
    }

    /// The confirmed voice a voice print belongs to, and how alike they are.
    static func match(_ print: [Double], in voices: [VoiceProfile]) -> (voice: VoiceProfile, similarity: Double)? {
        voices.map { v in (v, v.prints.map { cosine($0, print) }.max() ?? 0) }
            .filter { $0.1 >= sameVoice }
            .max { $0.1 < $1.1 }
    }
}

/// The phrase a person reads to confirm their voice: a fixed sentence plus three random
/// words, so an old recording or someone's clip can't be passed off as the reading.
enum ConsentPhrase {
    /// Words that are easy to read and to recognise, in the program's language.
    static let russian = [
        "река", "лимон", "окно", "гитара", "облако", "ключ", "собака", "зеркало", "трамвай", "подушка",
        "ракета", "мост", "кактус", "пирог", "фонарь", "чайник", "компас", "маяк", "орех", "дождь",
        "карандаш", "медведь", "корабль", "лестница", "бабочка", "вулкан", "письмо", "якорь", "тюльпан",
        "самолёт", "колокол", "радуга", "сундук", "жираф", "пчела", "огурец", "барабан", "апельсин",
        "снеговик", "черепаха",
    ]
    static let english = [
        "river", "lemon", "window", "guitar", "cloud", "key", "puppy", "mirror", "tram", "pillow",
        "rocket", "bridge", "cactus", "pie", "lantern", "kettle", "compass", "lighthouse", "walnut", "rain",
        "pencil", "bear", "ship", "ladder", "butterfly", "volcano", "letter", "anchor", "tulip",
        "airplane", "bell", "rainbow", "treasure", "giraffe", "bee", "cucumber", "drum", "orange",
        "snowman", "turtle",
    ]
    static var words: [String] { AppLanguage.isEnglish ? english : russian }

    static func make() -> String {
        let picked = words.shuffled().prefix(3).joined(separator: ", ")
        return String(localized: "Я разрешаю этой программе говорить моим голосом. Проверочные слова: \(picked).")
    }
}

/// The engine's answer about a reading.
struct VoiceCheck: Decodable {
    var ok: Bool
    /// silent, phrase, voice, maybe_voice
    var reason: String?
    var heard: String
    var textMatch: Double
    var similarity: Double?
    var print: [Double]?

    enum CodingKeys: String, CodingKey {
        case ok, reason, heard, similarity, print
        case textMatch = "text_match"
    }

    /// What to tell the person when the check did not pass.
    var problem: String? {
        switch reason {
        case nil: return nil
        case "silent": return String(localized: "Запись пустая или очень тихая. Проверьте микрофон и прочитайте ещё раз.")
        case "phrase": return String(localized: "Не получилось разобрать фразу\(heard.isEmpty ? "" : " (услышано: «\(heard)»)"). Прочитайте её ещё раз — чётко и целиком.")
        case "maybe_voice": return String(localized: "Голос похож не до конца. Попробуйте ещё раз в тишине, ближе к микрофону.")
        default: return String(localized: "Голос не похож на голос этого спикера в записи. Фразу должен прочитать сам человек, чей это голос.")
        }
    }
}
