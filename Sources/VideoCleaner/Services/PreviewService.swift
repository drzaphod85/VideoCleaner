// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AVFoundation
import CryptoKit
import Foundation
import VideoCleanerCore

/// Makes any supported file playable in AVPlayer. MP4/MOV with H.264/HEVC play directly; MKV is remuxed
/// (video copied, audio copied or converted to AAC) into a cached MP4 proxy with the same timeline;
/// exotic codecs get a small H.264 proxy made with VideoToolbox.
@MainActor
final class PreviewService {
    static let shared = PreviewService()

    enum Mode { case direct, remux, transcode }

    let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoCleaner/Previews", isDirectory: true)
    }()

    private var proxies: [String: URL] = [:]

    private static let directCodecs: Set<String> = ["h264", "hevc", "prores", "mpeg4", "mjpeg"]
    private static let copyAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    func prepare(url: URL, info: MediaInfo, tools: ToolPaths, forceTranscode: Bool = false,
                 progress: @escaping @MainActor (Double) -> Void) async throws -> (URL, Mode) {
        let ext = url.pathExtension.lowercased()
        let video = info.primaryVideo
        if !forceTranscode, ["mp4", "m4v", "mov"].contains(ext), let v = video, Self.directCodecs.contains(v.codec) {
            if (try? await AVURLAsset(url: url).load(.isPlayable)) == true { return (url, .direct) }
        }
        guard let v = video else { throw ProcessingError.failed(L("No video to show")) }
        guard let ffmpeg = tools.ffmpeg else { throw ProcessingError.missingTool("ffmpeg") }

        let transcode = forceTranscode || !["h264", "hevc"].contains(v.codec)
        let key = cacheKey(url: url, transcode: transcode)
        let out = cacheDir.appendingPathComponent("\(key).mp4")
        if FileManager.default.fileExists(atPath: out.path) {
            proxies[url.path] = out
            return (out, transcode ? .transcode : .remux)
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let part = cacheDir.appendingPathComponent("\(key).part.mp4")
        defer { try? FileManager.default.removeItem(at: part) }

        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        if FileScanner.isLegacy(url) { args += ["-fflags", "+genpts"] }
        args += ["-i", url.path, "-map", "0:\(v.index)"]
        if let a = info.audioStreams.first { args += ["-map", "0:\(a.index)"] }
        if transcode {
            args += ["-c:v", "h264_videotoolbox", "-b:v", "5M", "-vf", "scale=-2:'min(720,ih)',format=yuv420p",
                     "-fps_mode", "passthrough"]
        } else {
            args += ["-c:v", "copy"]
            if v.codec == "hevc" { args += ["-tag:v", "hvc1"] }
        }
        if let a = info.audioStreams.first {
            if Self.copyAudioCodecs.contains(a.codec) && !transcode {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "aac", "-ac", "2", "-b:a", "192k"]
            }
        }
        args += ["-sn", "-dn", "-map_chapters", "-1", "-map_metadata", "-1", "-f", "mp4", part.path]

        let duration = max(info.duration, 1)
        let r = try await ProcessRunner.run(ffmpeg, args, onStdoutLine: { line in
            guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
            let value = min(1, max(0, us / 1_000_000 / duration))
            Task { @MainActor in progress(value) }
        })
        guard r.status == 0 else {
            throw ProcessingError.failed(L("Could not create preview: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        try FileManager.default.moveItem(at: part, to: out)
        proxies[url.path] = out
        return (out, transcode ? .transcode : .remux)
    }

    /// Stereo AAC copies of audio streams, for listening to other tracks than the preview's own in the player.
    /// All streams of a file are made in one ffmpeg pass, since reading a large file is what takes time: asking
    /// for one stream starts (or joins) a job for every stream in `streams` not cached yet. Switching to another
    /// track never cancels the job. `progress` reports the job that makes the wanted stream.
    func prepareAudio(url: URL, streamIndex: Int, streams: [Int]? = nil, duration: Double, tools: ToolPaths,
                      background: Bool = false,
                      progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> URL {
        let wanted = audioURL(url, streamIndex)
        if FileManager.default.fileExists(atPath: wanted.path) { return wanted }
        let jobKey = "\(url.path)#\(streamIndex)"
        let job: AudioJob
        if let running = audioJobs[jobKey] {
            job = running
        } else {
            guard let ffmpeg = tools.ffmpeg else { throw ProcessingError.missingTool("ffmpeg") }
            let missing = Set((streams ?? []) + [streamIndex]).sorted()
                .filter { audioJobs["\(url.path)#\($0)"] == nil && !FileManager.default.fileExists(atPath: audioURL(url, $0).path) }
            job = AudioJob()
            for s in missing { audioJobs["\(url.path)#\(s)"] = job }
            job.task = Task { [weak self] in
                defer { for s in missing where self?.audioJobs["\(url.path)#\(s)"] === job { self?.audioJobs["\(url.path)#\(s)"] = nil } }
                try await self?.extractAudio(url: url, streams: missing, duration: duration, ffmpeg: ffmpeg,
                                             background: background) { p in job.report(p) }
            }
        }
        let token = job.listen(progress)
        defer { job.stopListening(token) }
        try await job.task?.value
        guard FileManager.default.fileExists(atPath: wanted.path) else {
            throw ProcessingError.failed(L("Could not prepare the audio for listening: %@", "a\(streamIndex)"))
        }
        return wanted
    }

    /// Starts making listening copies of the given streams in the background (e.g. all but the first when a
    /// file with several audio tracks is opened), so switching tracks in the player is immediate.
    func prefetchAudio(url: URL, streams: [Int], duration: Double, tools: ToolPaths) {
        guard let first = streams.first(where: { !FileManager.default.fileExists(atPath: audioURL(url, $0).path) }) else { return }
        Task { _ = try? await prepareAudio(url: url, streamIndex: first, streams: streams, duration: duration,
                                           tools: tools, background: true) }
    }

    /// Progress (0…1) of a running listening-copy job for a stream, nil when none is running.
    func audioProgress(url: URL, streamIndex: Int) -> Double? {
        audioJobs["\(url.path)#\(streamIndex)"]?.progress
    }

    func isAudioReady(url: URL, streamIndex: Int) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(url, streamIndex).path)
    }

    private func audioURL(_ url: URL, _ streamIndex: Int) -> URL {
        cacheDir.appendingPathComponent(cacheKey(url: url, transcode: false) + "-a\(streamIndex).m4a")
    }

    private func extractAudio(url: URL, streams: [Int], duration: Double, ffmpeg: URL, background: Bool,
                              progress: @escaping @MainActor (Double) -> Void) async throws {
        guard !streams.isEmpty else { return }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let outputs = streams.map { (audioURL(url, $0), cacheDir.appendingPathComponent(UUID().uuidString + ".part.m4a")) }
        defer { for (_, part) in outputs { try? FileManager.default.removeItem(at: part) } }
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats", "-i", url.path]
        for (s, (_, part)) in zip(streams, outputs) {
            args += ["-map", "0:\(s)", "-vn", "-sn", "-dn", "-ac", "2", "-c:a", "aac", "-b:a", "160k", "-f", "mp4", part.path]
        }
        let total = max(duration, 1)
        let r = try await ProcessRunner.run(ffmpeg, args, onStdoutLine: { line in
            guard line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) else { return }
            let value = min(1, max(0, us / 1_000_000 / total))
            Task { @MainActor in progress(value) }
        }, qualityOfService: background ? .utility : .userInitiated)
        guard r.status == 0 else {
            throw ProcessingError.failed(L("Could not prepare the audio for listening: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        for (out, part) in outputs { try? FileManager.default.moveItem(at: part, to: out) }
    }

    private var audioJobs: [String: AudioJob] = [:]

    /// One ffmpeg run making listening copies; several callers can wait for it and follow its progress.
    @MainActor
    private final class AudioJob {
        var task: Task<Void, Error>?
        private(set) var progress: Double = 0
        private var listeners: [UUID: @MainActor (Double) -> Void] = [:]

        func report(_ p: Double) {
            progress = p
            listeners.values.forEach { $0(p) }
        }

        func listen(_ f: @escaping @MainActor (Double) -> Void) -> UUID {
            let id = UUID()
            listeners[id] = f
            f(progress)
            return id
        }

        func stopListening(_ id: UUID) { listeners[id] = nil }
    }

    private func cacheKey(url: URL, transcode: Bool) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs?[.size] as? Int64 ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(url.path)|\(size)|\(mtime)|\(transcode ? "t" : "r")"
        return SHA256.hash(data: Data(raw.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Removes the proxy of a file that has been processed (its content changed).
    func invalidate(_ url: URL) {
        if let proxy = proxies.removeValue(forKey: url.path) { try? FileManager.default.removeItem(at: proxy) }
    }

    nonisolated func clearCache() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoCleaner/Previews", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    nonisolated func cacheSize() -> Int64 {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoCleaner/Previews", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// Timeline thumbnails from the playable asset. The fast generator may return a nearby keyframe (fine for
/// the overview); the exact one is used when zoomed in, where every tile must show its own moment.
final class ThumbnailProvider: @unchecked Sendable {
    private let fast: AVAssetImageGenerator
    private let exact: AVAssetImageGenerator
    private let cache = NSCache<NSString, NSImage>()

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        func make(tolerance: Double) -> AVAssetImageGenerator {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 240, height: 136)
            g.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
            return g
        }
        fast = make(tolerance: 2)
        exact = make(tolerance: 0)
        cache.countLimit = 800
    }

    private func key(_ t: Double, _ exact: Bool) -> NSString {
        exact ? "e\(Int(t * 25))" as NSString : "f\(Int(t * 2))" as NSString
    }

    func cached(at t: Double, exact: Bool = false) -> NSImage? { cache.object(forKey: key(t, exact)) }

    func image(at t: Double, exact: Bool = false) async -> NSImage? {
        let k = key(t, exact)
        if let img = cache.object(forKey: k) { return img }
        let generator = exact ? self.exact : fast
        guard let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: k)
        return img
    }
}

/// Small poster frames for the file list, made with ffmpeg (works for every container). Max 3 at a time.
actor PosterService {
    static let shared = PosterService()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if running < 3 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    func poster(for url: URL, duration: Double, tools: ToolPaths) async -> NSImage? {
        guard let ffmpeg = tools.ffmpeg else { return nil }
        await acquire()
        defer { release() }
        if Task.isCancelled { return nil }
        let t = duration > 30 ? min(duration * 0.1, 120) : duration / 3
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("vr-poster-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", String(format: "%.2f", t),
                    "-i", url.path, "-frames:v", "1", "-vf", "scale=192:-2", "-q:v", "4", out.path]
        guard let r = try? await ProcessRunner.run(ffmpeg, args), r.status == 0 else { return nil }
        return NSImage(contentsOf: out)
    }
}
