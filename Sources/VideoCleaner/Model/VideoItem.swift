// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import Observation
import VideoCleanerCore

/// Language rules applied to every file unless a track is changed by hand.
struct TrackRules: Equatable {
    /// Subtitle languages to select (empty = all).
    var subtitleLanguages: Set<String>
    /// Audio languages to remove.
    var removeAudioLanguages: Set<String>
}

@Observable @MainActor
final class VideoItem: Identifiable {
    enum Status: Equatable {
        case pending, running, done, failed(String), skipped(String), cancelled
    }

    let id = UUID()
    var url: URL
    var info: MediaInfo?
    var loadError: String?
    var poster: NSImage?

    var keyframes: [Double] = []
    var keyframesState: LoadState = .idle
    enum LoadState { case idle, loading, loaded, failed }

    /// Parts to remove from the video (timeline seconds).
    var removals: [TimeRange] = []
    /// Pending "mark in" point for a middle cut.
    var markIn: Double?
    var preciseCut = false

    var audioOverrides: [Int: Bool] = [:]
    var subtitleOverrides: [Int: Bool] = [:]
    var languageOverrides: [Int: String] = [:]

    var status: Status = .pending
    var progress: Double = 0
    var log: [LogEntry] = []
    var lastResult: ProcessingResult?

    init(url: URL) { self.url = url }

    var name: String { url.lastPathComponent }
    var duration: Double { info?.duration ?? 0 }

    var hasEdits: Bool {
        !removals.isEmpty || !audioOverrides.isEmpty || !subtitleOverrides.isEmpty || !languageOverrides.isEmpty
    }

    // MARK: Tracks

    func language(of s: StreamInfo) -> String { languageOverrides[s.index] ?? s.normalizedLanguage }

    func keepsAudio(_ s: StreamInfo, rules: TrackRules) -> Bool {
        audioOverrides[s.index] ?? !rules.removeAudioLanguages.contains(language(of: s))
    }

    func selectsSubtitle(_ s: StreamInfo, rules: TrackRules) -> Bool {
        subtitleOverrides[s.index] ?? (rules.subtitleLanguages.isEmpty || rules.subtitleLanguages.contains(language(of: s)))
    }

    /// True when the rules/choices would remove every audio track (the processor keeps all then).
    func removesAllAudio(rules: TrackRules) -> Bool {
        guard let info, !info.audioStreams.isEmpty else { return false }
        return !info.audioStreams.contains { keepsAudio($0, rules: rules) }
    }

    var tracksMissingLanguage: Int {
        guard let info else { return 0 }
        return (info.audioStreams + info.subtitleStreams).filter { language(of: $0) == "und" }.count
    }

    func setLanguage(_ code: String?, for s: StreamInfo) {
        if let code, Languages.normalized3(code) != s.normalizedLanguage {
            languageOverrides[s.index] = Languages.normalized3(code)
        } else {
            languageOverrides[s.index] = nil
        }
    }

    // MARK: Cuts

    func cutPlan(snapped: Bool = true) -> CutPlan {
        CutPlan(removals: removals, duration: duration, keyframes: keyframes, precise: preciseCut)
    }

    func addRemoval(_ r: TimeRange) {
        removals = Cuts.normalize(removals + [r], duration: duration)
    }

    func setRemovals(_ list: [TimeRange]) {
        removals = Cuts.normalize(list, duration: duration)
    }

    func resetEdits() {
        removals = []
        markIn = nil
        preciseCut = false
        audioOverrides = [:]
        subtitleOverrides = [:]
        languageOverrides = [:]
    }

    func makeJob(options: ProcessingOptions, rules: TrackRules) -> ProcessingJob? {
        guard let info else { return nil }
        return ProcessingJob(
            input: url, info: info, keyframes: keyframes,
            keepAudio: Set(info.audioStreams.filter { keepsAudio($0, rules: rules) }.map(\.index)),
            selectedSubtitles: Set(info.subtitleStreams.filter { selectsSubtitle($0, rules: rules) }.map(\.index)),
            languages: languageOverrides, removals: removals, preciseCut: preciseCut, options: options)
    }
}
