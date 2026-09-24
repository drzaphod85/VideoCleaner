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

        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats",
                    "-i", url.path, "-map", "0:\(v.index)"]
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

/// Timeline thumbnails from the playable asset (cached, low resolution, keyframe-tolerant for speed).
final class ThumbnailProvider: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let cache = NSCache<NSNumber, NSImage>()

    init(url: URL) {
        let asset = AVURLAsset(url: url)
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 136)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        cache.countLimit = 600
    }

    func cached(at t: Double) -> NSImage? { cache.object(forKey: NSNumber(value: Int(t * 2))) }

    func image(at t: Double) async -> NSImage? {
        let key = NSNumber(value: Int(t * 2))
        if let img = cache.object(forKey: key) { return img }
        guard let cg = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
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
