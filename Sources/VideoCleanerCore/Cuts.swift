// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A time range in seconds (timeline = container time minus file start time).
public struct TimeRange: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public init(_ start: Double, _ end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    public var length: Double { end - start }
    public func contains(_ t: Double) -> Bool { t >= start && t < end }
}

public enum Cuts {
    /// Clamps to [0, duration], sorts and merges overlapping/touching ranges.
    public static func normalize(_ ranges: [TimeRange], duration: Double) -> [TimeRange] {
        let clamped = ranges
            .map { TimeRange(max(0, min($0.start, duration)), max(0, min($0.end, duration))) }
            .filter { $0.length > 0.001 }
            .sorted { $0.start < $1.start }
        var merged: [TimeRange] = []
        for r in clamped {
            if let last = merged.last, r.start <= last.end + 0.0005 {
                merged[merged.count - 1].end = max(last.end, r.end)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// Index of the first element >= t.
    private static func lowerBound(_ t: Double, in sorted: [Double]) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public static func nearestKeyframe(to t: Double, in keyframes: [Double]) -> Double? {
        guard !keyframes.isEmpty else { return nil }
        let i = lowerBound(t, in: keyframes)
        if i == 0 { return keyframes[0] }
        if i == keyframes.count { return keyframes[i - 1] }
        return (t - keyframes[i - 1] <= keyframes[i] - t) ? keyframes[i - 1] : keyframes[i]
    }

    public static func keyframe(atOrBefore t: Double, in keyframes: [Double]) -> Double? {
        let i = lowerBound(t + 1e-9, in: keyframes)
        return i > 0 ? keyframes[i - 1] : nil
    }

    public static func nextKeyframe(after t: Double, in keyframes: [Double]) -> Double? {
        let i = lowerBound(t + 0.002, in: keyframes)
        return i < keyframes.count ? keyframes[i] : nil
    }

    public static func previousKeyframe(before t: Double, in keyframes: [Double]) -> Double? {
        let i = lowerBound(t - 0.002, in: keyframes)
        return i > 0 ? keyframes[i - 1] : nil
    }

    public static func isKeyframe(_ t: Double, in keyframes: [Double], tolerance: Double = 0.002) -> Bool {
        guard let k = nearestKeyframe(to: t, in: keyframes) else { return false }
        return abs(k - t) <= tolerance
    }
}

/// What is kept after the removals, and where each kept segment effectively starts when streams are copied
/// (at the keyframe at or before the requested start) or re-encoded (exactly at the requested start).
public struct CutPlan: Sendable {
    public struct Segment: Sendable, Equatable {
        public let requestedStart: Double
        public let start: Double
        public let end: Double
        public var length: Double { end - start }
        public var startsOnKeyframe: Bool { abs(requestedStart - start) < 0.002 }
    }

    public let duration: Double
    public let removals: [TimeRange]
    public let segments: [Segment]
    public let precise: Bool

    public init(removals: [TimeRange], duration: Double, keyframes: [Double], precise: Bool) {
        self.duration = duration
        self.precise = precise
        let norm = Cuts.normalize(removals, duration: duration)
        self.removals = norm
        var keeps: [(Double, Double)] = []
        var cursor = 0.0
        for r in norm {
            if r.start - cursor > 0.04 { keeps.append((cursor, r.start)) }
            cursor = max(cursor, r.end)
        }
        if duration - cursor > 0.04 { keeps.append((cursor, duration)) }
        segments = keeps.map { s, e in
            var effective = s
            if !precise && s > 0.0005 && !keyframes.isEmpty {
                effective = Cuts.keyframe(atOrBefore: s + 0.001, in: keyframes) ?? 0
            }
            return Segment(requestedStart: s, start: min(effective, s), end: e)
        }
    }

    public var isCutting: Bool { !removals.isEmpty }
    public var outputDuration: Double { segments.reduce(0) { $0 + $1.length } }
    public var misalignedSegments: [Segment] { segments.filter { !$0.startsOnKeyframe } }

    /// Maps a subtitle cue from source time to output time. A cue spanning a cut is clipped;
    /// cues entirely inside removed parts disappear.
    public func map(_ cue: SubtitleCue) -> [SubtitleCue] {
        guard isCutting else { return [cue] }
        var result: [SubtitleCue] = []
        var offset = 0.0
        for seg in segments {
            let lo = max(cue.start, seg.start)
            let hi = min(cue.end, seg.end)
            if hi - lo > 0.02 {
                result.append(SubtitleCue(start: lo - seg.start + offset, end: hi - seg.start + offset, text: cue.text))
            }
            offset += seg.length
        }
        return result
    }
}
