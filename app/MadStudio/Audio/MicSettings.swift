import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// How in-app recordings are processed: a preset («Студия», «Подкаст»…) or the person's own
/// numbers, optionally fitted to their voice by «Настроить автоматически» (speak quietly,
/// then loudly). Applied after recording; the untouched recording is kept too.
struct MicSettings: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case asIs, studio, podcast, stream, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .asIs: return String(localized: "Как есть")
            case .studio: return String(localized: "Студия")
            case .podcast: return String(localized: "Подкаст")
            case .stream: return String(localized: "Стрим (громко и плотно)")
            case .custom: return String(localized: "Свои настройки")
            }
        }
        var about: String {
            switch self {
            case .asIs: return String(localized: "Без обработки — как записал микрофон.")
            case .studio: return String(localized: "Бережно: лёгкое выравнивание громкости, естественный звук.")
            case .podcast: return String(localized: "Ровная громкость, мягкие «с» и «ш», разборчивость голоса.")
            case .stream: return String(localized: "Сильнее выравнивает: тихие слова подтянуты, крики не перегружают.")
            case .custom: return String(localized: "Ваши числа ниже.")
            }
        }
    }

    var preset = Preset.podcast
    var highpass = 80.0          // Hz: cut rumble below
    var gate = -60.0             // dBFS: quieter than this between words is muted (-60 — off)
    var threshold = -22.0        // dBFS: the compressor starts working above this
    var ratio = 3.0
    var makeup = 4.0             // dB added after compression
    var deesser = 0.4            // 0…1
    var presence = 2.0           // dB at 4 kHz: clarity
    var limiter = -1.5           // dBFS: nothing goes above
    /// 0…1: evens out quiet and loud phrases (measured: a phrase 15 dB quieter ends up
    /// 2 dB quieter at 0.3, 1 dB at 0.5; a compressor alone leaves 9 dB)
    var leveler = 0.3
    /// measured by «Настроить автоматически»: speech level when quiet and when loud (dBFS)
    var quiet: Double?
    var loud: Double?

    init() {}

    // settings saved before a field existed keep working
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MicSettings()
        preset = try c.decodeIfPresent(Preset.self, forKey: .preset) ?? d.preset
        highpass = try c.decodeIfPresent(Double.self, forKey: .highpass) ?? d.highpass
        gate = try c.decodeIfPresent(Double.self, forKey: .gate) ?? d.gate
        threshold = try c.decodeIfPresent(Double.self, forKey: .threshold) ?? d.threshold
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        makeup = try c.decodeIfPresent(Double.self, forKey: .makeup) ?? d.makeup
        deesser = try c.decodeIfPresent(Double.self, forKey: .deesser) ?? d.deesser
        presence = try c.decodeIfPresent(Double.self, forKey: .presence) ?? d.presence
        limiter = try c.decodeIfPresent(Double.self, forKey: .limiter) ?? d.limiter
        leveler = try c.decodeIfPresent(Double.self, forKey: .leveler) ?? d.leveler
        quiet = try c.decodeIfPresent(Double.self, forKey: .quiet)
        loud = try c.decodeIfPresent(Double.self, forKey: .loud)
    }

    static func preset(_ p: Preset) -> MicSettings {
        var s = MicSettings()
        s.preset = p
        switch p {
        case .asIs, .custom: break
        case .studio: (s.highpass, s.gate, s.ratio, s.makeup, s.deesser, s.presence, s.leveler) = (70, -60, 2, 2, 0.2, 1, 0)
        case .podcast: (s.highpass, s.gate, s.ratio, s.makeup, s.deesser, s.presence, s.leveler) = (80, -55, 3, 4, 0.4, 2, 0.3)
        case .stream: (s.highpass, s.gate, s.ratio, s.makeup, s.deesser, s.presence, s.leveler) = (90, -50, 4.5, 6, 0.5, 3, 0.8)
        }
        return s
    }

    /// Fits the compressor to this voice: it starts a little above the quiet speech, and the
    /// makeup brings quiet speech to a comfortable level (about −18 dBFS).
    mutating func calibrate(quiet q: Double, loud l: Double) {
        quiet = q
        loud = l
        let span = max(3, l - q)
        threshold = (q + span * 0.3).rounded()
        let quietAfter = q   // below the threshold quiet speech isn't compressed
        makeup = min(14, max(0, (-18 - quietAfter) * 0.6)).rounded()
        gate = max(-70, min(-45, q - 20)).rounded()
        // a voice that is much quieter at times needs the phrases evened out
        if span > 10 && preset != .studio { leveler = max(leveler, min(0.8, (span - 6) / 20)) }
    }

    /// The ffmpeg filter chain for these settings ("" — nothing to do).
    var chain: String {
        guard preset != .asIs else { return "" }
        var parts = ["highpass=f=\(Int(highpass))"]
        if gate > -59 { parts.append("agate=threshold=\(fmt(pow(10, gate / 20))):ratio=3:attack=5:release=150") }
        if leveler > 0.01 {
            parts.append("dynaudnorm=f=400:g=31:p=0.6:m=\(fmt(2 + leveler * 14)):r=0")
        }
        if presence != 0 { parts.append("equalizer=f=4000:t=q:w=1.2:g=\(fmt(presence))") }
        if deesser > 0.01 { parts.append("deesser=i=\(fmt(deesser))") }
        parts.append("acompressor=threshold=\(fmt(threshold))dB:ratio=\(fmt(ratio)):attack=8:release=120:makeup=\(fmt(max(1, pow(10, makeup / 20))))")
        parts.append("alimiter=limit=\(fmt(pow(10, limiter / 20))):level=false")
        return parts.joined(separator: ",")
    }

    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

    // storage
    static var current: MicSettings {
        get {
            (UserDefaults.standard.data(forKey: "micSettings")).flatMap { try? JSONDecoder().decode(MicSettings.self, from: $0) }
                ?? MicSettings.preset(.podcast)
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "micSettings") }
    }
}

/// Speech level of a recording: the louder half of the 50 ms frames that hold sound, in dBFS,
/// and the highest peak.
enum Loudness {
    static func measure(_ url: URL) -> (speech: Double, peak: Double)? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return nil }
        let n = Int(buffer.frameLength), frame = Int(file.processingFormat.sampleRate * 0.05)
        guard n > frame else { return nil }
        var levels: [Double] = []
        var peak: Float = 0
        vDSP_maxmgv(data, 1, &peak, vDSP_Length(n))
        var i = 0
        while i + frame <= n {
            var ms: Float = 0
            vDSP_measqv(data + i, 1, &ms, vDSP_Length(frame))
            let db = 10 * log10(Double(ms) + 1e-12)
            if db > -55 { levels.append(db) }
            i += frame
        }
        guard !levels.isEmpty else { return nil }
        let loud = levels.sorted().suffix(max(1, levels.count / 2))
        return (loud.reduce(0, +) / Double(loud.count), 20 * log10(Double(peak) + 1e-9))
    }
}

/// The microphone's input level in macOS (the slider in System Settings → Sound → Input),
/// when the device lets programs change it.
enum SystemMic {
    private static var device: AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 0…1, or nil when this microphone has no adjustable level (many USB mics, AirPods…).
    static var level: Float? {
        get {
            guard let id = device else { return nil }
            var address = volumeAddress()
            guard AudioObjectHasProperty(id, &address) else { return nil }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
        }
        set {
            guard let id = device, var value = newValue else { return }
            var address = volumeAddress()
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return }
            value = min(1, max(0, value))
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }
}
