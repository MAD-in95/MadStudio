import AppKit

/// Developer helpers for the progress diary; never used in normal work.
///
/// `--snapshot <file.png> [--snapshot-delay <s>]` saves a picture of the window and quits.
/// `--record <file.mov> [--record-seconds <s>]` records a short video (10–15 s) of the window and quits.
/// Flags without a value (`--auto-clean`, `--show-models`) must go last:
/// AppKit reads "-name value" pairs as settings and would swallow them otherwise.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let path = value("--snapshot") {
            let delay = value("--snapshot-delay").flatMap(Double.init) ?? 5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(to: path)
                exit(0)
            }
        }
        runUIScript()
        if let path = value("--record") {
            let seconds = min(value("--record-seconds").flatMap(Double.init) ?? 12, 15)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                record(to: path, seconds: seconds)
            }
        }
    }

    /// `--ui "drag 500,400 600,400; click 300,200; rclick 300,200; key v; wait 1"`: mouse and
    /// keys sent into the app's own window (points from the window's top-left corner), to check
    /// the timeline by hand without touching the real mouse. Runs `--ui-delay` s after launch.
    @MainActor
    static func runUIScript() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--ui"), i + 1 < args.count else { return }
        let delay = args.firstIndex(of: "--ui-delay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 4
        let steps = args[i + 1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // a background window only takes the first click as "bring me forward"
            NSApp.activate()
            Self.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(500))
            var host: NSView?
            for step in steps {
                let parts = step.split(separator: " ").map(String.init)
                guard let window = Self.window, let kind = parts.first else { continue }
                func point(_ s: String) -> NSPoint {
                    let xy = s.split(separator: ",").compactMap { Double($0) }
                    let h = window.contentView?.frame.height ?? window.frame.height
                    return NSPoint(x: xy[0], y: h - xy[1])
                }
                func send(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
                    guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
                    else { return }
                    if type == .leftMouseDown || type == .rightMouseDown {
                        log("\(kind) at \(p), window key=\(window.isKeyWindow), app active=\(NSApp.isActive)")
                    }
                    if window.isKeyWindow {
                        window.sendEvent(e)
                        return
                    }
                    // a background window swallows the first click: hand the event to the SwiftUI
                    // host view under the pointer (it runs the gestures itself)
                    if type == .leftMouseDown || type == .rightMouseDown {
                        var v = window.contentView?.superview?.hitTest(p)
                        while let view = v, !String(describing: Swift.type(of: view)).contains("HostingView") { v = view.superview }
                        host = v ?? window.contentView
                        log("  host: \(host.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                    }
                    switch type {
                    case .leftMouseDown: host?.mouseDown(with: e)
                    case .leftMouseDragged: host?.mouseDragged(with: e)
                    case .leftMouseUp: host?.mouseUp(with: e)
                    case .rightMouseDown: host?.rightMouseDown(with: e)
                    case .rightMouseUp: host?.rightMouseUp(with: e)
                    default: break
                    }
                }
                switch kind {
                case "click":
                    send(.leftMouseDown, point(parts[1])); send(.leftMouseUp, point(parts[1]))
                case "dclick":
                    send(.leftMouseDown, point(parts[1])); send(.leftMouseUp, point(parts[1]))
                    send(.leftMouseDown, point(parts[1]), clicks: 2); send(.leftMouseUp, point(parts[1]), clicks: 2)
                case "rclick":
                    send(.rightMouseDown, point(parts[1])); send(.rightMouseUp, point(parts[1]))
                case "drag", "sdrag":   // sdrag: slowly, to be seen on a video
                    let a = point(parts[1]), b = point(parts[2])
                    let n = kind == "sdrag" ? 50 : 12
                    send(.leftMouseDown, a)
                    for k in 1...n {
                        let f = Double(k) / Double(n)
                        send(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                        try? await Task.sleep(for: .milliseconds(kind == "sdrag" ? 30 : 20))
                    }
                    if kind == "sdrag" { try? await Task.sleep(for: .milliseconds(500)) }
                    send(.leftMouseUp, b)
                case "press":      // press and drag without letting go (to see a drag in a snapshot)
                    let a = point(parts[1]), b = point(parts[2])
                    send(.leftMouseDown, a)
                    for k in 1...12 {
                        let f = Double(k) / 12
                        send(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                case "key":
                    log("key \(parts[1]) -> first responder \(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
                    let isDelete = parts[1] == "delete"
                    let chars = isDelete ? "\u{7F}" : parts[1]
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false,
                                                keyCode: isDelete ? 51 : 0) {
                        if window.isKeyWindow { window.sendEvent(e) } else { (window.firstResponder ?? window).keyDown(with: e) }
                    }
                case "wait":
                    try? await Task.sleep(for: .seconds(Double(parts[1]) ?? 1))
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    static func log(_ line: String) {
        let url = AppPaths.home.appendingPathComponent("ui.log")
        let text = line + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.className.contains("AppKitWindow") }
            ?? NSApp.windows.first { $0.isVisible }
    }

    /// A real screenshot of the window only (needs screen-recording permission); falls back
    /// to drawing the view, where glass panels come out blank.
    @MainActor
    private static func snapshot(to path: String) {
        log("snapshot: windows \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible) sheet=\($0.isSheet)" })")
        guard let main = window else { return }
        // an open sheet (e.g. «Модели») is its own window
        // `--settings`: the Settings window instead of the main one
        let settings = CommandLine.arguments.contains("--settings") ? NSApp.windows.first { $0.isVisible && $0 !== main } : nil
        let window = settings ?? main.attachedSheet ?? NSApp.windows.first { $0.isVisible && $0.isSheet } ?? main
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? capture.run()
        capture.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { return }
        if let view = window.contentView?.superview,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    private static func record(to path: String, seconds: Double) {
        guard let window, let screen = window.screen else { return }
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        // screencapture wants top-left based screen points; only the window area is recorded
        let frame = window.frame
        let top = screen.frame.maxY - frame.maxY
        let rect = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-v", "-V", String(Int(seconds)), "-R", rect, path]
        capture.terminationHandler = { _ in exit(0) }
        try? capture.run()
    }
}
