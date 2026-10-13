import Accelerate
import AVFoundation

/// Loudness overview of a recording: one value (0…1, on a decibel scale) per 1/20 s,
/// cached in the project folder.
enum Waveform {
    static let peaksPerSecond = 20.0

    static func load(source: URL, cache: URL) async -> [Float] {
        if let data = try? Data(contentsOf: cache), !data.isEmpty {
            return data.map { Float($0) / 255 }
        }
        let peaks = await Task.detached(priority: .utility) { compute(source) }.value
        let bytes = Data(peaks.map { UInt8(min(255, max(0, $0 * 255))) })
        try? bytes.write(to: cache)
        return peaks
    }

    private static func compute(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16)
        else { return [] }
        let window = max(1, Int(file.processingFormat.sampleRate / peaksPerSecond))
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / Double(window)) + 1)
        // RMS in dB, -50 dB…0 dB mapped to 0…1: pauses look low, speech looks tall
        func level(_ meanSquare: Float) -> Float {
            min(1, max(0, (10 * log10(meanSquare + 1e-12) + 50) / 50))
        }
        var carry: [Float] = []   // samples left over between reads
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let channels = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)
            var mono = Array(UnsafeBufferPointer(start: channels[0], count: count))
            if buffer.format.channelCount > 1 {
                vDSP.add(mono, UnsafeBufferPointer(start: channels[1], count: count), result: &mono)
                vDSP.multiply(0.5, mono, result: &mono)
            }
            carry += mono
            var start = 0
            while carry.count - start >= window {
                peaks.append(level(vDSP.meanSquare(carry[start..<start + window])))
                start += window
            }
            carry.removeFirst(start)
        }
        if !carry.isEmpty { peaks.append(level(vDSP.meanSquare(carry))) }
        return peaks
    }
}
