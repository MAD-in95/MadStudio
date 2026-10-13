import AVFoundation
import SwiftUI

/// «Настройки микрофона»: a preset, the microphone's level in macOS, «Настроить
/// автоматически» (speak quietly, then loudly — the program fits the compressor to the
/// voice) and fine-tuning by hand.
struct MicSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MicSettings.current
    @State private var systemLevel = SystemMic.level
    @State private var step = Step.idle
    @State private var recorder = Recorder()
    @State private var note: String?
    @State private var player: AVAudioPlayer?
    @State private var processed: URL?
    @State private var fine = false

    private enum Step: Equatable { case idle, quiet, loud, working }

    private var folder: URL {
        let url = AppPaths.home.appendingPathComponent("mic-check")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var quietFile: URL { folder.appendingPathComponent("quiet.wav") }
    private var loudFile: URL { folder.appendingPathComponent("loud.wav") }
    private var bothFile: URL { folder.appendingPathComponent("both.wav") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Настройки микрофона").font(.title2.bold())
                Spacer()
                Label(Recorder.inputName, systemImage: "mic").foregroundStyle(Theme.Colors.muted)
            }
            presets
            Divider()
            level
            Divider()
            auto
            DisclosureGroup("Тонкая настройка", isExpanded: $fine) { manual.padding(.top, 8) }
            HStack {
                Text("Обработка накладывается после записи; исходная запись тоже сохраняется.")
                    .font(.caption).foregroundStyle(Theme.Colors.muted)
                Spacer()
                Button("Готово") { MicSettings.current = settings; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onChange(of: settings) { MicSettings.current = settings }
        .onDisappear { recorder.stop(); player?.stop() }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Звук записи").panelHeader()
            ForEach(MicSettings.Preset.allCases) { p in
                Button {
                    let measured = (settings.quiet, settings.loud)
                    settings = p == .custom ? { var s = settings; s.preset = .custom; return s }() : MicSettings.preset(p)
                    if p != .asIs && p != .custom, let q = measured.0, let l = measured.1 { settings.calibrate(quiet: q, loud: l) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: settings.preset == p ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.preset == p ? Theme.Colors.accent : Theme.Colors.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.title).font(.system(size: 13, weight: .medium))
                            Text(p.about).font(.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var level: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Уровень микрофона в macOS").panelHeader()
            if let value = systemLevel {
                HStack {
                    Image(systemName: "speaker.wave.1").foregroundStyle(Theme.Colors.muted)
                    Slider(value: Binding(get: { Double(value) }, set: { v in systemLevel = Float(v); SystemMic.level = Float(v) }), in: 0...1)
                    Text("\(Int(value * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .help("Тот же уровень, что в Системных настройках → Звук → Вход")
            } else {
                Text("У этого микрофона уровень меняется только на нём самом (или в его программе) — программа подстроит громкость обработкой.")
                    .font(.caption).foregroundStyle(Theme.Colors.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var auto: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Настроить автоматически").panelHeader()
            switch step {
            case .idle:
                Text("Скажите фразу тихо, потом громко — программа подберёт уровень микрофона и компрессор под ваш голос.")
                    .font(.callout).foregroundStyle(Theme.Colors.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { Task { await calibrate() } } label: { Label("Начать (8 секунд)", systemImage: "waveform.badge.mic") }
                        .buttonStyle(.borderedProminent)
                    if processed != nil {
                        Button { play(bothFile) } label: { Label("Было", systemImage: "play") }
                            .help("Послушать проверочную запись без обработки")
                        Button { if let processed { play(processed) } } label: { Label("Стало", systemImage: "play.fill") }
                            .help("Послушать её с выбранной обработкой")
                    }
                }
            case .quiet, .loud:
                Text(step == .quiet ? String(localized: "Тихо, как будто рядом спят:") : String(localized: "А теперь громко и уверенно:"))
                    .font(.callout.weight(.semibold))
                Text(step == .quiet ? String(localized: "«Раз, два, три — это мой тихий голос»") : String(localized: "«Раз, два, три — это мой громкий голос!»"))
                    .font(.title3)
                ProgressView(value: Double(recorder.level)).frame(width: 300)
            case .working:
                HStack { ProgressView().controlSize(.small); Text("Считаю…") }
            }
            if let note {
                Text(note).font(.callout).foregroundStyle(Theme.Colors.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manual: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            row(String(localized: "Выравнивание фраз"), $settings.leveler, 0...1, "", String(localized: "Подтягивает тихие фразы к громким: 0 — выключено, 1 — сильно"))
            row(String(localized: "Срез низа"), $settings.highpass, 40...200, String(localized: "Гц"), String(localized: "Убирает гул и стук ниже этой частоты"))
            row(String(localized: "Шумовой гейт"), $settings.gate, -70 ... -30, String(localized: "дБ"), String(localized: "Глушит тихий фон между словами; −60 и ниже — выключен"))
            row(String(localized: "Компрессор: порог"), $settings.threshold, -45 ... -6, String(localized: "дБ"), String(localized: "Громче этого — звук сжимается"))
            row(String(localized: "Компрессор: сила"), $settings.ratio, 1...8, ":1", String(localized: "Насколько сильно сжимать громкие места"))
            row(String(localized: "Усиление после"), $settings.makeup, 0...15, String(localized: "дБ"), String(localized: "Подтянуть общую громкость после сжатия"))
            row(String(localized: "Мягкость «с»"), $settings.deesser, 0...1, "", String(localized: "Де-эссер: смягчает свист на «с», «ш», «щ»"))
            row(String(localized: "Разборчивость"), $settings.presence, -3...6, String(localized: "дБ"), String(localized: "Подъём около 4 кГц — голос чётче"))
            row(String(localized: "Потолок"), $settings.limiter, -6 ... -0.1, String(localized: "дБ"), String(localized: "Выше этого звук не поднимется — без перегрузки"))
        }
        .font(.callout)
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String, _ help: String) -> some View {
        GridRow {
            Text(title)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; settings.preset = .custom }), in: range)
                .frame(width: 220)
            Text("\(Format.seconds(value.wrappedValue)) \(unit)").monospacedDigit().foregroundStyle(Theme.Colors.muted)
        }
        .help(help)
    }

    private func record(_ url: URL, seconds: Double) async -> Bool {
        do { try recorder.start(to: url) } catch { note = error.localizedDescription; return false }
        try? await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        return true
    }

    private func calibrate() async {
        note = nil
        guard await Recorder.requestAccess() else {
            note = String(localized: "Нет доступа к микрофону: Системные настройки → Конфиденциальность и безопасность → Микрофон.")
            return
        }
        step = .quiet
        guard await record(quietFile, seconds: 4) else { step = .idle; return }
        step = .loud
        guard await record(loudFile, seconds: 4) else { step = .idle; return }
        step = .working
        defer { step = .idle }
        guard let q = Loudness.measure(quietFile), let l = Loudness.measure(loudFile) else {
            note = String(localized: "Не расслышал голос — проверьте, тот ли микрофон выбран, и попробуйте ещё раз.")
            return
        }
        var lines = [String(localized: "Тихо: \(Int(q.speech)) дБ, громко: \(Int(l.speech)) дБ, пик \(Int(l.peak)) дБ.")]
        // the microphone's own level first: loud speech should peak around −6 dB
        if var level = systemLevel {
            if l.peak > -3 {
                level *= Float(pow(10, (-6 - l.peak) / 20))
                lines.append(String(localized: "Громко было на грани перегрузки — уровень микрофона снижен до \(Int(level * 100))%."))
            } else if l.peak < -20 {
                level = min(1, level * Float(pow(10, min(12, -12 - l.peak) / 20)))
                lines.append(String(localized: "Микрофон тихий — уровень поднят до \(Int(level * 100))%."))
            }
            SystemMic.level = level
            systemLevel = SystemMic.level
        } else if l.peak > -1 {
            lines.append(String(localized: "Громко звук перегружается, а уровень этого микрофона программа менять не может: отодвиньтесь или убавьте его на самом микрофоне."))
        }
        if settings.preset == .asIs || settings.preset == .custom { settings = MicSettings.preset(.podcast) }
        settings.calibrate(quiet: q.speech, loud: l.speech)
        lines.append(String(localized: "Компрессор начинает с \(Int(settings.threshold)) дБ, усиление +\(Int(settings.makeup)) дБ — тихие слова подтянуты, громкие не перегружают."))
        note = lines.joined(separator: " ")
        await preview()
    }

    /// The two check recordings one after the other, and the same with the processing.
    private func preview() async {
        let out = folder.appendingPathComponent("both-processed.wav")
        do {
            // quiet + loud, one after the other
            let a = try AVAudioFile(forReading: quietFile), b = try AVAudioFile(forReading: loudFile)
            let out1 = try AVAudioFile(forWriting: bothFile, settings: a.fileFormat.settings)
            for f in [a, b] {
                guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else { continue }
                try f.read(into: buf)
                try out1.write(from: buf)
            }
            _ = try await Engine.run(["audiofx", bothFile.path, out.path, settings.chain.isEmpty ? "anull" : settings.chain])
            processed = out
        } catch {
            note = (note ?? "") + String(localized: " (Послушать не получилось: \(error.localizedDescription))")
        }
    }

    private func play(_ url: URL) {
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}
