import Foundation

/// Pure editing rules, kept apart from the UI so they are easy to test.
enum Editing {
    /// Parts of the original recording that remain after the edits, merged where they touch.
    static func keepRanges(tokens: [Token], states: [TokenState], keepPause: Double,
                           replacements: [Replacement] = []) -> [TimeRange] {
        timeline(tokens: tokens, states: states, keepPause: keepPause, replacements: replacements, folder: nil)
            .compactMap { if case .original(let r) = $0 { return r } else { return nil } }
    }

    /// The edited recording as a list of pieces: kept parts of the original, re-voiced
    /// inserts and silence put in on the timeline.
    static func timeline(tokens: [Token], states: [TokenState], keepPause: Double,
                         replacements: [Replacement], folder: URL?,
                         arrangement: Arrangement = Arrangement()) -> [Segment] {
        var segments: [Segment] = []
        let breaks = arrangement.breaks
        var cut = false        // the next piece starts a new clip
        var gap = 0.0          // silence waiting to go in before the next piece
        func add(_ s: Double, _ e: Double) {
            guard e > s else { return }
            if gap > 0.0005 {
                segments.append(.silence(gap))
                gap = 0
            }
            if !cut, case .original(let last)? = segments.last, abs(last.end - s) < 0.0005 {
                segments[segments.count - 1] = .original(TimeRange(start: last.start, end: e))
            } else {
                segments.append(.original(TimeRange(start: s, end: e)))
            }
            cut = false
        }
        let starting = Dictionary(replacements.map { ($0.first, $0) }, uniquingKeysWith: { a, _ in a })
        var i = 0
        while i < min(tokens.count, states.count) {
            gap += arrangement.gaps[i] ?? 0
            if breaks.contains(i) { cut = true }
            if let r = starting[i], r.last < tokens.count {
                if gap > 0.0005 {
                    segments.append(.silence(gap))
                    gap = 0
                }
                let url = (folder ?? URL(fileURLWithPath: "/")).appendingPathComponent(r.file)
                segments.append(.generated(file: url, duration: r.duration, at: tokens[i].start))
                cut = false
                i = r.last + 1
                continue
            }
            let token = tokens[i], state = states[i]
            i += 1
            let kept = state == .delete ? 0 : arrangement.pauses[i - 1].map { min($0, token.duration) }
                ?? (state == .shorten ? min(keepPause, token.duration) : token.duration)
            if kept >= token.duration - 0.0005 {
                add(token.start, token.end)
            } else if kept > 0.0005 {
                // keep both edges so the words around the pause stay untouched
                add(token.start, token.start + kept / 2)
                add(token.end - kept / 2, token.end)
            }
        }
        return segments
    }

    /// How much of token i stays in the edited recording (seconds).
    static func keptLength(_ i: Int, tokens: [Token], states: [TokenState], keepPause: Double,
                           arrangement: Arrangement) -> Double {
        let d = tokens[i].duration
        switch states[i] {
        case .delete: return 0
        case .keep: return arrangement.pauses[i].map { min($0, d) } ?? d
        case .shorten: return arrangement.pauses[i].map { min($0, d) } ?? min(keepPause, d)
        }
    }

    /// Marks what "Почистить автоматически" should remove. Words are never touched,
    /// except parasite sounds like "ээ" that Whisper wrote down as words.
    static func autoClean(tokens: [Token], states: [TokenState], options: CleanOptions) -> [TokenState] {
        zip(tokens, states).map { token, state in
            if token.take != nil && options.takes { return .delete }
            switch token.kind {
            case .pause:
                return options.pauses && token.duration > options.maxPause ? .shorten : .keep
            case .breath:
                return options.breaths ? .delete : .keep
            case .filler:
                return options.fillers ? .delete : .keep
            case .click:
                return options.clicks ? .delete : .keep
            case .speech:
                return state == .shorten ? .keep : state
            case .word:
                if token.parasite == true { return options.fillers ? .delete : .keep }
                return state == .shorten ? .keep : state
            }
        }
    }

    static func duration(of segments: [Segment]) -> Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    static func duration(of ranges: [TimeRange]) -> Double {
        ranges.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// Whether time t survives the edits (ranges are sorted).
    static func isKept(_ t: Double, in ranges: [TimeRange]) -> Bool {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if t < ranges[mid].start { hi = mid - 1 } else if t >= ranges[mid].end { lo = mid + 1 } else { return true }
        }
        return false
    }

    /// Index of the token playing at time t (tokens are sorted and contiguous).
    static func tokenIndex(at t: Double, in tokens: [Token]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        var lo = 0, hi = tokens.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tokens[mid].start <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
