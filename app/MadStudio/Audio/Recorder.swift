import AVFoundation
import Observation

/// Records the microphone to a WAV file: voice recordings for a project, the voice
/// confirmation phrase.
@Observable
@MainActor
final class Recorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    /// the loudest moment lately, 0…1 (near 1 — too loud, the sound gets distorted)
    private(set) var peak: Float = 0
    /// loudness of the voice right now, 0…1 (for the level bar)
    private(set) var level: Float = 0
    private(set) var elapsed: Double = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    /// The microphone macOS records from (as chosen in System Settings → Sound).
    static var inputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? String(localized: "микрофон")
    }

    /// Asks macOS for the microphone the first time; false if the person said no.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false,
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw EngineError.failed(String(localized: "Не получилось начать запись с микрофона")) }
        recorder = r
        isRecording = true
        isPaused = false
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        guard isRecording else { return }
        if isPaused { recorder?.record() } else { recorder?.pause() }
        isPaused.toggle()
    }

    func stop() {
        isPaused = false
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        level = 0
    }

    private func tick() {
        guard let r = recorder else { return }
        r.updateMeters()
        level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
        let p = max(0, min(1, (r.peakPower(forChannel: 0) + 50) / 50))
        peak = max(p, peak - 0.01)
        if r.currentTime > 0 { elapsed = r.currentTime }
    }
}
