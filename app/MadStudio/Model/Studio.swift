import AVFoundation
import Foundation

/// A file in a project's media library.
struct MediaItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case speech, music, effect }

    var id = UUID()
    var path: String          // the sound (for a video: its sound taken out once)
    var original: String      // what the person brought in
    var name: String
    var duration: Double
    var kind: Kind

    var url: URL { URL(fileURLWithPath: path) }

    /// A first guess the person can change: short sounds are effects, "music"/"музык…"
    /// in the name — music, everything else — speech.
    static func guessKind(name: String, duration: Double) -> Kind {
        let n = name.lowercased()
        if ["music", "музык", "song", "трек", "beat", "бит"].contains(where: n.contains) { return .music }
        return duration <= 15 ? .effect : .speech
    }
}

/// A project as in editing programs: a media library and what is on the tracks. The speech
/// recording on the voice track is edited through its text (its own `Project`).
struct StudioDoc: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var modified = Date()
    var media: [MediaItem] = []
    /// the recording on the voice track (path of its sound), nil — the tracks are empty
    var recording: String?
    /// music and effects put on the tracks before there was a recording
    var pendingMusic: [UserClip] = []
    var pendingEffects: [UserClip] = []
}

/// One line in «Недавние проекты»: a project, or a recording opened before projects existed.
struct RecentItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var date: Date
    var doc: StudioDoc?
    var legacy: URL?
}

@MainActor
enum StudioStore {
    static var folder: URL {
        let url = AppPaths.home.appendingPathComponent("studio")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func save(_ doc: StudioDoc) {
        var doc = doc
        doc.modified = Date()
        try? encoder.encode(doc).write(to: file(doc.id))
    }

    static func all() -> [StudioDoc] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(StudioDoc.self, from: $0) } }
            .sorted { $0.modified > $1.modified }
    }

    /// Removes a project from the list (its files and edits stay where they are).
    static func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// A free name like «Проект 3».
    static func newName() -> String {
        let names = Set(all().map(\.name))
        var n = 1
        while names.contains(String(localized: "Проект \(n)")) { n += 1 }
        return String(localized: "Проект \(n)")
    }

    /// Projects and older opened recordings, newest first.
    static func recent() -> [RecentItem] {
        let docs = all()
        let used = Set(docs.flatMap { d in d.media.map(\.path) + [d.recording].compactMap { $0 } })
        var items = docs.map { d in
            RecentItem(id: d.id.uuidString, title: d.name, subtitle: summary(d), date: d.modified, doc: d)
        }
        // recordings transcribed before there were projects
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: AppPaths.projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let transcriptURL = Project.transcriptURL(in: folder)
            guard let data = try? Data(contentsOf: transcriptURL),
                  let t = try? JSONDecoder().decode(Transcript.self, from: data) else { continue }
            let source = t.source.hasPrefix("/") ? URL(fileURLWithPath: t.source)
                : Engine.directory.appendingPathComponent(t.source).standardizedFileURL
            guard fm.fileExists(atPath: source.path), !used.contains(source.path) else { continue }
            let edits = folder.appendingPathComponent("edits.json")
            let date = [edits, transcriptURL].compactMap {
                (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }.max() ?? .distantPast
            items.append(RecentItem(id: source.path, title: source.deletingPathExtension().lastPathComponent,
                                    subtitle: String(localized: "запись · \(Format.time(t.duration))"), date: date, legacy: source))
        }
        return items.sorted { $0.date > $1.date }
    }

    static func summary(_ d: StudioDoc) -> String {
        let n = d.media.count
        let files = n == 0 ? String(localized: "пустой") : AppLanguage.isEnglish ? "\(n) file\(n == 1 ? "" : "s")"
            : "\(n) \(n % 10 == 1 && n % 100 != 11 ? "файл" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "файла" : "файлов")"
        if let rec = d.recording, let item = d.media.first(where: { $0.path == rec }) {
            return "\(files) · \(Format.time(item.duration))"
        }
        return files
    }

    /// Brings a file into a library: the sound is taken out of a video once.
    static func mediaItem(for url: URL) async throws -> MediaItem {
        let audio = try await Pipeline.audio(for: url)
        let duration = (try? AVAudioFile(forReading: audio)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        let name = url.deletingPathExtension().lastPathComponent
        return MediaItem(path: audio.path, original: url.path, name: name, duration: duration,
                         kind: MediaItem.guessKind(name: name, duration: duration))
    }
}
