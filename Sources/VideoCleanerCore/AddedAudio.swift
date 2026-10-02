// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// An audio track taken from another file (e.g. a Swedish dub) and placed on the movie's timeline.
///
/// Placement: the sound at time `s` in the source plays at movie time `s * stretch + offset`.
/// `stretch` corrects a speed difference (e.g. 25/23.976 for PAL TV audio against a 23.976 fps film);
/// `trimStart`/`trimEnd` (source time) cut away unwanted parts of the source such as a channel ident.
public struct AddedAudio: Codable, Hashable, Sendable, Identifiable {
    public var id = UUID()
    public var source: URL
    /// Absolute stream index in the source file.
    public var streamIndex: Int
    public var codec: String
    public var channels: Int
    public var channelLayout: String?
    public var sampleRate: Int
    public var sourceDuration: Double

    public var language: String
    public var title: String
    public var isDefault: Bool

    public var offset: Double = 0
    public var stretch: Double = 1
    public var trimStart: Double = 0
    public var trimEnd: Double?

    public init(source: URL, stream: StreamInfo, sourceDuration: Double) {
        self.source = source
        streamIndex = stream.index
        codec = stream.codec
        channels = stream.channels ?? 2
        channelLayout = stream.channelLayout
        sampleRate = stream.sampleRate ?? 48_000
        self.sourceDuration = sourceDuration
        language = stream.hasLanguage ? stream.normalizedLanguage : "und"
        title = stream.title ?? ""
        isDefault = false
    }

    public func movieTime(ofSource s: Double) -> Double { s * stretch + offset }
    public func sourceTime(ofMovie t: Double) -> Double { (t - offset) / stretch }

    /// The part of the movie timeline that has sound from this track.
    public var movieRange: TimeRange {
        TimeRange(movieTime(ofSource: trimStart), movieTime(ofSource: trimEnd ?? sourceDuration))
    }

    public var isStretched: Bool { abs(stretch - 1) > 0.00001 }

    public var summary: String {
        var parts = [codec.uppercased()]
        if let l = channelLayout, !l.isEmpty { parts.append(l.replacingOccurrences(of: "(side)", with: "")) }
        else { parts.append(L("%lld ch", channels)) }
        return parts.joined(separator: " · ")
    }

    /// Well-known speed ratios between frame rates (source → film).
    public static let knownStretches: [(ratio: Double, label: String)] = [
        (1, "1:1"),
        (25 / (24000.0 / 1001), "25 → 23.976 (PAL)"),
        ((24000.0 / 1001) / 25, "23.976 → 25"),
        (25 / 24.0, "25 → 24"),
        (24 / 25.0, "24 → 25"),
        (24 / (24000.0 / 1001), "24 → 23.976"),
        ((24000.0 / 1001) / 24, "23.976 → 24"),
    ]

    public static func label(forStretch s: Double) -> String? {
        knownStretches.first { abs($0.ratio - s) < 0.00005 }?.label
    }
}
