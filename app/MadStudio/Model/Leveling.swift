import Foundation

/// «Выровнять громкость собеседников» (like Auphonic's leveler between speakers): measures how
/// loud each speaker talks and sets their track volumes so everyone sounds equally loud. Works
/// from the loudness overview the program already keeps (20 values a second), so it is instant.
enum Leveling {
    /// less speech than this gives an unreliable level: such a speaker is left as is
    static let minSpeech = 8.0
    static let maxGain = 12.0

    /// Typical speech level of each speaker, dB: the louder half of the moments inside their
    /// words (pauses and fading word ends would pull it down), averaged as energy.
    static func levels(tokens: [Token], peaks: [Float], perSecond: Double = Waveform.peaksPerSecond) -> [Int: Double] {
        var frames: [Int: [Double]] = [:]
        for t in tokens where t.isWord {
            let a = max(0, Int(t.start * perSecond)), b = min(peaks.count, Int((t.end * perSecond).rounded(.up)))
            guard a < b else { continue }
            frames[t.speaker ?? 0, default: []] += peaks[a..<b].map { Double($0) * 50 - 50 }   // 0…1 -> −50…0 dB
        }
        var out: [Int: Double] = [:]
        for (speaker, db) in frames where Double(db.count) / perSecond >= minSpeech {
            let loud = db.sorted().suffix(max(1, db.count / 2))
            let power = loud.map { pow(10, $0 / 10) }.reduce(0, +) / Double(loud.count)
            out[speaker] = 10 * log10(power)
        }
        return out
    }

    /// Volume change per speaker to bring everyone to the middle level (rounded to 0.5 dB).
    static func gains(for levels: [Int: Double]) -> [Int: Double] {
        guard levels.count > 1 else { return [:] }
        let sorted = levels.values.sorted()
        let target = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return levels.mapValues { level in
            (min(maxGain, max(-maxGain, target - level)) * 2).rounded() / 2
        }
    }
}

extension Project {
    /// Sets the speakers' track volumes so they sound equally loud (one undo step).
    /// Returns the change per speaker, empty when there is nothing to level.
    @discardableResult
    func levelSpeakers(peaks: [Float]) -> [Int: Double] {
        let gains = Leveling.gains(for: Leveling.levels(tokens: tokens, peaks: peaks))
        guard !gains.isEmpty else { return [:] }
        changeMix { mix in
            for (speaker, gain) in gains {
                mix.tracks[Lane.key(.speaker(speaker)), default: TrackSettings()].gainDB = gain
            }
        }
        return gains
    }
}
