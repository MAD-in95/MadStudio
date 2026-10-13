import Foundation

/// A message from the Python engine (one JSON line on its stdout).
struct EngineEvent {
    var event: String
    var stage: String?
    var value: Double?
    var start: Double?
    var text: String?
    var message: String?
}

enum EngineError: LocalizedError {
    case failed(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .notFound(let path): return String(localized: "Не найден движок MadStudio: \(path)")
        }
    }
}

/// Runs the Python engine as a separate process: `python -m madstudio_engine <args>`.
enum Engine {
    /// The engine packed inside the app (a build for other people), if there is one.
    static var bundled: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("engine"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("madstudio_engine").path) else { return nil }
        return url
    }

    static var directory: URL {
        if let bundled { return bundled }
        let path = Bundle.main.object(forInfoDictionaryKey: "MadStudioEngineDir") as? String ?? ""
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Its own Python inside the app, or the developer's environment next to the code.
    static var python: URL {
        bundled.map { $0.appendingPathComponent("python/bin/python3.12") }
            ?? directory.appendingPathComponent(".venv/bin/python")
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let bundled {
            // our own ffmpeg first; nothing from the person's own Python setup leaks in,
            // and nothing is written inside the app
            let tools = bundled.deletingLastPathComponent().appendingPathComponent("bin").path
            env["PATH"] = tools + ":/usr/bin:/bin:/usr/sbin:/sbin"
            for key in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "VIRTUAL_ENV"] { env[key] = nil }
            env["PYTHONNOUSERSITE"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            let cache = AppPaths.home.appendingPathComponent("cache").path
            env["NUMBA_CACHE_DIR"] = cache + "/numba"
            env["MPLCONFIGDIR"] = cache + "/matplotlib"
        } else {
            // Apps started from Finder don't see Homebrew; the engine needs its ffmpeg.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        }
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["MADSTUDIO_LANG"] = AppLanguage.current      // the engine's messages in the same language
        return env
    }

    static let missingModel = Notification.Name("MadStudioMissingModel")

    /// A step stopped because a model isn't downloaded: the app offers to download it.
    static func reportMissing(_ model: String) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: missingModel, object: model) }
    }

    /// Runs a command, forwards progress events and returns the JSON `result` of the "done" event.
    static func run(_ arguments: [String],
                    onEvent: @escaping @MainActor (EngineEvent) -> Void = { _ in }) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw EngineError.notFound(python.path)
        }

        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "madstudio_engine"] + arguments
        process.currentDirectoryURL = directory
        process.environment = environment

        let stdout = Pipe()
        process.standardOutput = stdout
        let logURL = AppPaths.logs.appendingPathComponent("engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: logURL)

        try process.run()

        var result: Data?
        var failure: String?
        // cancelling the Swift task stops the engine process (e.g. «Отменить» on a long job)
        try await withTaskCancellationHandler {
        for try await line in stdout.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["event"] as? String
            else { continue }
            let event = EngineEvent(
                event: name,
                stage: json["stage"] as? String,
                value: json["value"] as? Double,
                start: json["start"] as? Double,
                text: json["text"] as? String,
                message: json["message"] as? String)
            switch name {
            case "done":
                result = try? JSONSerialization.data(withJSONObject: json["result"] ?? [:], options: [.fragmentsAllowed])
            case "error":
                failure = event.message
                if let model = json["model"] as? String { Engine.reportMissing(model) }
            default:
                await onEvent(event)
            }
        }
        } onCancel: {
            process.terminate()
        }
        process.waitUntilExit()
        if Task.isCancelled { throw CancellationError() }

        if let failure { throw EngineError.failed(failure) }
        guard let result, process.terminationStatus == 0 else {
            throw EngineError.failed(String(localized: "Движок завершился с ошибкой (код \(process.terminationStatus)). Подробности: \(logURL.path)"))
        }
        return result
    }
}

/// A model from the engine's catalog.
struct ModelInfo: Decodable, Identifiable {
    var id: String
    var family: String
    var task: String
    var title: String
    var description: String
    var size_gb: Double
    var ram_gb: Double
    var russian: String
    var license: String
    var `default`: Bool?
    var hidden: Bool?
    var installed: Bool
    /// how well it suits this Mac: "ok", "slow", "no_memory", "no_disk"
    var fit: String?
    var note: String?
    /// real model name, size in billions of parameters and number format ("FP16", "4 бита")
    var model_name: String?
    var params_b: Double?
    var precision: String?
    /// the model this task runs with
    var chosen: Bool?
    var repo: String?

    var technical: String? {
        guard let name = model_name, let params = params_b else { return nil }
        let size = params >= 0.1
            ? Format.decimal(params, digits: 2) + String(localized: " млрд")
            : String(format: "%.0f", params * 1000) + String(localized: " млн")
        return String(localized: "\(name) · \(size) параметров · \(precision ?? "")")
    }
}

struct DeviceInfo: Decodable {
    var chip: String
    var ram_gb: Int
    var disk_free_gb: Int
}

/// The engine kept running between commands, so heavy models load once: the first
/// re-voicing loads the voice model (~20 s), the next ones start right away. The engine
/// quits by itself after 5 idle minutes, and is stopped when another recording opens.
@MainActor
final class WarmEngine {
    private var process: Process?
    private var input: FileHandle?
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator?
    private var busy = false

    var isRunning: Bool { process?.isRunning ?? false }

    func stop() {
        process?.terminate()
        process = nil
        input = nil
        lines = nil
    }

    private func start() throws {
        let python = Engine.python
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw EngineError.notFound(python.path) }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "madstudio_engine", "serve"]
        p.currentDirectoryURL = Engine.directory
        p.environment = Engine.environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        let logURL = AppPaths.logs.appendingPathComponent("engine-warm.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = try FileHandle(forWritingTo: logURL)
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        lines = stdout.fileHandleForReading.bytes.lines.makeAsyncIterator()
    }

    /// Runs one command in the warm engine, like `Engine.run`.
    func run(_ arguments: [String], onEvent: @escaping @MainActor (EngineEvent) -> Void = { _ in }) async throws -> Data {
        guard !busy else { return try await Engine.run(arguments, onEvent: onEvent) }
        busy = true
        defer { busy = false }
        if !isRunning { stop(); try start() }
        guard let input, var iterator = lines else { throw EngineError.failed(String(localized: "Движок не запустился")) }
        input.write(try JSONSerialization.data(withJSONObject: arguments) + Data("\n".utf8))

        var result: Data?
        var failure: String?
        try await withTaskCancellationHandler {
            while let line = try await iterator.next() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = json["event"] as? String else { continue }
                if name == "end" { break }
                switch name {
                case "done":
                    result = try? JSONSerialization.data(withJSONObject: json["result"] ?? [:], options: [.fragmentsAllowed])
                case "error":
                    failure = json["message"] as? String
                    if let model = json["model"] as? String { Engine.reportMissing(model) }
                default:
                    onEvent(EngineEvent(event: name, stage: json["stage"] as? String, value: json["value"] as? Double,
                                        start: json["start"] as? Double, text: json["text"] as? String,
                                        message: json["message"] as? String))
                }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
        lines = iterator
        if Task.isCancelled { throw CancellationError() }
        if let failure { throw EngineError.failed(failure) }
        guard let result else {
            stop()
            throw EngineError.failed(String(localized: "Движок остановился. Подробности: \(AppPaths.logs.appendingPathComponent("engine-warm.log").path)"))
        }
        return result
    }
}

/// Result of the speed test: how fast this Mac runs the models, and time estimates.
struct SpeedInfo: Codable {
    struct Estimate: Codable, Identifiable {
        var id: String
        var title: String
        var seconds: Double
        var per: String
    }
    var chip: String
    var ram_gb: Int
    var compute_tflops: Double
    var bandwidth_gbs: Double
    var relative: Double
    var estimates: [Estimate]
    var date: Date?

    func seconds(_ id: String) -> Double? { estimates.first { $0.id == id }?.seconds }
}


/// A model found on Hugging Face for a task.
struct HubModel: Decodable, Identifiable {
    var repo: String
    var title: String
    var author: String
    var task: String
    var installed: Bool
    var experimental: Bool
    var params_b: Double?
    var precision: String?
    var size_gb: Double?
    var ram_gb: Double?
    var downloads: Int
    var updated: String
    var fit: String?
    var note: String?
    var id: String { repo }
}


/// Where the models are kept and how much room they take.
struct ModelsFolder: Decodable {
    var path: String
    var custom: Bool
    var available: Bool
    var used_gb: Double
    var free_gb: Double
}
