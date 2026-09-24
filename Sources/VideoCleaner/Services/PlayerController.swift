// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation
import Observation
import VideoCleanerCore

@Observable @MainActor
final class PlayerController {
    enum State: Equatable {
        case empty
        case preparing(Double?, String)
        case ready
        case failed(String)
    }

    let player = AVPlayer()
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var state: State = .empty
    var frameDuration: Double = 1.0 / 25.0
    var thumbnails: ThumbnailProvider?
    var previewMode: PreviewService.Mode?
    /// Set when the shown file changed on disk (after processing) and the preview must be rebuilt.
    var needsReload = false
    /// Removed parts that playback jumps over when `skipRemoved` is on.
    var skipRanges: [TimeRange] = []
    var skipRemoved = false

    private(set) var itemID: UUID?
    private var loadedURL: URL?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: (Double, Bool)?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.isPlaying = playing } }
        }
    }

    private func tick(_ t: CMTime) {
        guard !seekInFlight, t.isNumeric else { return }
        let s = t.seconds
        currentTime = s
        if skipRemoved && isPlaying, let r = skipRanges.first(where: { $0.contains(s) && $0.end - s > 0.05 }) {
            if r.end >= duration - 0.05 {
                pause()
            } else {
                seek(to: r.end, precise: false)
            }
        }
    }

    func load(item: VideoItem, tools: ToolPaths) {
        guard let info = item.info else { return }
        if itemID == item.id && loadedURL == item.url && !needsReload && state != .empty { return }
        needsReload = false
        loadTask?.cancel()
        pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        thumbnails = nil
        previewMode = nil
        itemID = item.id
        loadedURL = item.url
        duration = info.duration
        frameDuration = info.frameDuration
        currentTime = 0
        state = .preparing(nil, L("Preparing preview…"))
        let url = item.url
        loadTask = Task { await prepare(url: url, info: info, tools: tools, forceTranscode: false) }
    }

    private func prepare(url: URL, info: MediaInfo, tools: ToolPaths, forceTranscode: Bool) async {
        do {
            let (playURL, mode) = try await PreviewService.shared.prepare(
                url: url, info: info, tools: tools, forceTranscode: forceTranscode) { [weak self] p in
                guard let self, self.loadedURL == url else { return }
                let label = forceTranscode || !["h264", "hevc"].contains(info.primaryVideo?.codec ?? "")
                    ? L("Creating preview (re-encoding)…") : L("Preparing preview…")
                self.state = .preparing(p, label)
            }
            guard !Task.isCancelled, loadedURL == url else { return }
            let item = AVPlayerItem(url: playURL)
            previewMode = mode
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                let status = it.status
                let message = it.error?.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.loadedURL == url else { return }
                        if status == .failed {
                            if mode != .transcode {
                                self.state = .preparing(nil, L("Creating preview (re-encoding)…"))
                                self.loadTask = Task { await self.prepare(url: url, info: info, tools: tools, forceTranscode: true) }
                            } else {
                                self.state = .failed(message ?? L("The file cannot be played"))
                            }
                        } else if status == .readyToPlay {
                            self.state = .ready
                        }
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            thumbnails = ThumbnailProvider(url: playURL)
            if currentTime > 0 { seek(to: currentTime) }
        } catch is CancellationError {
        } catch {
            guard loadedURL == url else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func unload() {
        loadTask?.cancel()
        pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        thumbnails = nil
        state = .empty
        itemID = nil
        loadedURL = nil
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard state == .ready else { return }
        if currentTime >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    func pause() { player.pause() }

    /// Seeks with chasing: while a seek is running only the latest target is kept.
    func seek(to t: Double, precise: Bool = true) {
        let target = min(max(0, t), max(0, duration - 0.001))
        currentTime = target
        guard player.currentItem != nil else { return }
        if seekInFlight {
            pendingSeek = (target, precise)
            return
        }
        seekInFlight = true
        let tol = precise ? CMTime.zero : CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 90_000), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.seekInFlight = false
                    if let (next, p) = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: next, precise: p)
                    }
                }
            }
        }
    }

    func step(frames: Int) {
        pause()
        if let item = player.currentItem, state == .ready, abs(frames) == 1 {
            item.step(byCount: frames)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { self.currentTime = self.player.currentTime().seconds }
            }
        } else {
            seek(to: currentTime + Double(frames) * frameDuration)
        }
    }
}
