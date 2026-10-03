// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VideoCleanerCore

/// Runs the processing with the ffmpeg that is bundled in the app (Vendor/ffmpeg, built by
/// Scripts/build-ffmpeg.sh), to make sure the LGPL build has everything VideoCleaner needs.
/// Sample files are still made with the installed ffmpeg (which has encoders such as libx264).
@Suite(.serialized) struct BundledFFmpegTests {
    static let vendor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/ffmpeg")

    @Test func bundledBuildProcessesEverything() async throws {
        let installed = ToolPaths.locate()
        guard let maker = installed.ffmpeg,
              FileManager.default.isExecutableFile(atPath: Self.vendor.appendingPathComponent("ffmpeg").path) else { return }
        var bundled = ToolPaths()
        bundled.ffmpeg = Self.vendor.appendingPathComponent("ffmpeg")
        bundled.ffprobe = Self.vendor.appendingPathComponent("ffprobe")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-bundled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let avi = dir.appendingPathComponent("old.avi"), dub = dir.appendingPathComponent("dub.dts")
        try writeWAV(SyntheticSound(duration: 25, effectsSeed: 3, voiceSeed: 4).render(seconds: 20), to: dir.appendingPathComponent("a.wav"))
        var r = try await ProcessRunner.run(maker, ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=20", "-i", dir.appendingPathComponent("a.wav").path,
            "-c:v", "mpeg4", "-vtag", "XVID", "-bf", "2", "-g", "25", "-c:a", "libmp3lame", "-ar", "44100", avi.path])
        #expect(r.status == 0, "\(r.stderr)")
        r = try await ProcessRunner.run(maker, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "sine=f=330:duration=22:sample_rate=48000", "-ac", "6", "-c:a", "dca", "-strict", "-2", dub.path])
        #expect(r.status == 0, "\(r.stderr)")

        let info = try await Probe.mediaInfo(avi, tools: bundled)
        let kfs = try await Probe.keyframes(avi, info: info, tools: bundled)
        let cut = try #require(kfs.first { $0 >= 3 })
        let dubInfo = try await Probe.mediaInfo(dub, tools: bundled)
        var track = AddedAudio(source: dub, stream: dubInfo.audioStreams[0], sourceDuration: dubInfo.duration)
        track.language = "swe"; track.offset = 1.5; track.stretch = 25 / (24000.0 / 1001)   // DTS → AC-3, PAL-corrected
        var options = ProcessingOptions(); options.trashOriginalAfterConversion = false
        let job = ProcessingJob(input: avi, info: info, keyframes: kfs, keepAudio: Set(info.audioStreams.map(\.index)),
                                selectedSubtitles: [], removals: [TimeRange(0, cut)], addedAudio: [track], options: options)
        let log = LogBox()
        let result = try await Processor(tools: bundled).process(job, log: { log.add($0) }, progress: { _ in })
        let out = try await Probe.mediaInfo(result.output, tools: bundled)
        #expect(result.output.pathExtension == "mkv", "\(log.text)")
        #expect(out.primaryVideo?.codec == "mpeg4")
        #expect(out.audioStreams.map(\.codec) == ["mp3", "ac3"], "\(log.text)")
        #expect(abs(out.duration - (info.duration - cut)) < 0.3, "duration \(out.duration)")

        // Synchronization decodes with the bundled ffmpeg too
        _ = try await AudioSync.features(of: dub, streamIndex: dubInfo.audioStreams[0].index, tools: bundled)
    }

    @Test func bundledBuildIsChosenWhenNotOlder() {
        guard FileManager.default.isExecutableFile(atPath: Self.vendor.appendingPathComponent("ffmpeg").path) else { return }
        let t = ToolPaths.locate(bundledDirectory: Self.vendor)
        #expect(t.bundledFFmpegVersion != nil)
        if t.ffmpegSource == .installed {
            #expect(ToolPaths.isNewer(t.ffmpegVersion, than: t.bundledFFmpegVersion))
        } else {
            #expect(t.ffmpegSource == .bundled && t.ffprobe?.deletingLastPathComponent() == Self.vendor)
        }
    }
}
