// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VideoCleanerCore

/// Older containers are converted to MKV without re-encoding, also when "keep format" is chosen.
@Suite(.serialized) struct LegacyFormatTests {
    let tools = ToolPaths.locate()

    static let samples: [(ext: String, args: [String])] = [
        ("avi", ["-c:v", "mpeg4", "-vtag", "XVID", "-bf", "2", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "128k"]),
        ("vob", ["-c:v", "mpeg2video", "-b:v", "3M", "-c:a", "ac3", "-f", "vob"]),
        ("mpg", ["-c:v", "mpeg2video", "-c:a", "mp2"]),
        ("wmv", ["-c:v", "wmv2", "-b:v", "2M", "-c:a", "wmav2"]),
        ("flv", ["-c:v", "flv1", "-b:v", "1M", "-c:a", "libmp3lame", "-ar", "44100"]),
        ("ts", ["-c:v", "libx264", "-g", "25", "-c:a", "aac", "-f", "mpegts"]),
        ("webm", ["-c:v", "libvpx-vp9", "-b:v", "1M", "-deadline", "realtime", "-c:a", "libopus"]),
    ]

    func makeSample(_ ext: String, _ args: [String], in dir: URL) async throws -> URL? {
        guard let ffmpeg = tools.ffmpeg else { return nil }
        let url = dir.appendingPathComponent("old.\(ext)")
        let r = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=12", "-f", "lavfi", "-i", "sine=f=440:duration=12"]
            + args + [url.path])
        return r.status == 0 ? url : nil   // an encoder missing from this ffmpeg build: skip that format
    }

    @Test(arguments: samples.map(\.ext)) func convertsToMKV(ext: String) async throws {
        guard tools.hasFFmpeg else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let src = try await makeSample(ext, Self.samples.first { $0.ext == ext }!.args, in: dir) else { return }

        #expect(FileScanner.isVideo(src) && FileScanner.isLegacy(src))
        let info = try await Probe.mediaInfo(src, tools: tools)
        var options = ProcessingOptions()
        options.convertToMKV = false            // legacy formats become MKV anyway
        options.trashOriginalAfterConversion = false
        // Cut at a keyframe after ~4 s, to exercise seeking and keyframes in the old container without re-encoding
        let kfs = try await Probe.keyframes(src, info: info, tools: tools)
        let cut = try #require(kfs.first { $0 >= 3.5 })
        let job = ProcessingJob(input: src, info: info, keyframes: kfs, keepAudio: Set(info.audioStreams.map(\.index)),
                                selectedSubtitles: [], removals: [TimeRange(0, cut)], options: options)
        let log = LogBox()
        let result = try await Processor(tools: tools).process(job, log: { log.add($0) }, progress: { _ in })
        #expect(result.output.pathExtension == "mkv", "\(log.text)")
        let out = try await Probe.mediaInfo(result.output, tools: tools)
        #expect(out.primaryVideo?.codec == info.primaryVideo?.codec, "video must be copied, not re-encoded")
        #expect(out.audioStreams.count == 1)
        #expect(abs(out.duration - (info.duration - cut)) < 0.3, "duration \(out.duration), cut at \(cut)\n\(log.text)")
        #expect(FileManager.default.fileExists(atPath: src.path), "original kept")
    }
}
