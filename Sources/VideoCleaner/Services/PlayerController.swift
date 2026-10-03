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
    /// Plays an added audio track in sync with the video (the film's own sound is muted meanwhile).
    let audioPlayer = AVPlayer()
    var previewTrack: AddedAudio?
    /// When one of the film's own tracks (other than the one in the preview) is being listened to: its stream index.
    var listeningStream: Int?
    var audioPreview: AudioPreview = .off
    enum AudioPreview: Equatable { case off, preparing(Double), ready, failed(String) }

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
    @ObservationIgnored private var audioLoadTask: Task<Void, Never>?
    @ObservationIgnored private var audioSource: (URL, Int)?
    /// After (re)scheduling the audio, leave it alone until it is actually playing.
    @ObservationIgnored private var audioHoldUntil = Date.distantPast
    @ObservationIgnored private var pendingSeek: (Double, Bool)?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isPlaying = playing
                    self?.syncAudio(force: true)
                }
            }
        }
        audioPlayer.automaticallyWaitsToMinimizeStalling = false
    }

    private func tick(_ t: CMTime) {
        guard !seekInFlight, t.isNumeric else { return }
        let s = t.seconds
        currentTime = s
        syncAudio(force: false)
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
        if itemID != item.id { setPreviewTrack(nil, tools: tools) }
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
        setPreviewTrack(nil, tools: ToolPaths())
        loadTask?.cancel()
        pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        thumbnails = nil
        state = .empty
        itemID = nil
        loadedURL = nil
    }

    // MARK: Listening to an added track

    /// Starts (or stops, with nil) listening to an added track. Also call it after the track's offset,
    /// speed or trims changed, so the sound follows at once.
    func setPreviewTrack(_ track: AddedAudio?, tools: ToolPaths) {
        listeningStream = nil
        guard let track else {
            audioLoadTask?.cancel()
            previewTrack = nil
            audioPreview = .off
            audioPlayer.pause()
            audioPlayer.replaceCurrentItem(with: nil)
            audioSource = nil
            player.isMuted = false
            return
        }
        previewTrack = track
        if let src = audioSource, src.0 == track.source, src.1 == track.streamIndex, audioPreview == .ready {
            player.isMuted = true
            syncAudio(force: true)
            return
        }
        audioLoadTask?.cancel()
        audioPreview = .preparing(0)
        let source = track.source, stream = track.streamIndex, duration = track.sourceDuration
        audioLoadTask = Task {
            do {
                let url = try await PreviewService.shared.prepareAudio(url: source, streamIndex: stream, duration: duration,
                                                                      tools: tools) { [weak self] p in
                    if case .preparing = self?.audioPreview { self?.audioPreview = .preparing(p) }
                }
                guard !Task.isCancelled, previewTrack?.source == source else { return }
                let item = AVPlayerItem(url: url)
                item.audioTimePitchAlgorithm = .varispeed   // slower also means lower, like the speed correction
                audioPlayer.replaceCurrentItem(with: item)
                audioSource = (source, stream)
                audioPreview = .ready
                player.isMuted = true
                syncAudio(force: true)
            } catch is CancellationError {
            } catch {
                audioPreview = .failed(error.localizedDescription)
            }
        }
    }

    /// Keeps the added track's sound where the video is: source time = (movie time − offset) / stretch.
    /// Both players are tied to the host clock: the audio player is told to be at a given source time at a given
    /// host time a moment from now, computed from the video's own timebase — so they run in lockstep.
    private func syncAudio(force: Bool) {
        guard let t = previewTrack, audioPreview == .ready, let audioItem = audioPlayer.currentItem,
              audioItem.status == .readyToPlay else { return }
        let src = t.sourceTime(ofMovie: currentTime)
        let inside = src >= t.trimStart && src < (t.trimEnd ?? t.sourceDuration)
        guard isPlaying && inside, let videoBase = player.currentItem?.timebase else {
            if audioPlayer.rate != 0 { audioPlayer.pause() }
            audioHoldUntil = .distantPast
            return
        }
        if !force && Date() < audioHoldUntil { return }

        // Compare both players at the same host-clock instant
        let host = CMClockGetHostTimeClock()
        let hostNow = CMClockGetTime(host)
        let videoNow = CMSyncConvertTime(hostNow, from: host, to: videoBase).seconds
        let expected = t.sourceTime(ofMovie: videoNow)
        let audioNow = audioItem.timebase.map { CMSyncConvertTime(hostNow, from: host, to: $0).seconds }
            ?? audioPlayer.currentTime().seconds
        let rate = Float(1 / t.stretch)
        guard force || audioPlayer.rate == 0 || abs(audioNow - expected) > 0.025 else { return }

        let lead = 0.12   // start a moment ahead so the audio player has time to get there
        let videoThen = videoNow + lead * Double(CMTimebaseGetRate(videoBase))
        audioPlayer.setRate(rate, time: CMTime(seconds: t.sourceTime(ofMovie: videoThen), preferredTimescale: 48_000),
                            atHostTime: CMTimeAdd(hostNow, CMTime(seconds: lead, preferredTimescale: 1_000_000_000)))
        audioHoldUntil = Date().addingTimeInterval(lead + 0.4)
    }

    /// For diagnostics: how far the added track's sound is from where it should be (seconds, + = ahead).
    var audioSyncError: Double? {
        guard let t = previewTrack, let a = audioPlayer.currentItem?.timebase, let v = player.currentItem?.timebase,
              audioPlayer.rate != 0 else { return nil }
        let host = CMClockGetHostTimeClock(), now = CMClockGetTime(host)
        return CMSyncConvertTime(now, from: host, to: a).seconds - t.sourceTime(ofMovie: CMSyncConvertTime(now, from: host, to: v).seconds)
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

    func pause() {
        player.pause()
        audioPlayer.pause()
    }

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

