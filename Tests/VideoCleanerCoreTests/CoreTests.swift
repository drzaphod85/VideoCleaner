// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VideoCleanerCore

@Suite struct LanguageTests {
    @Test func normalizes() {
        #expect(Languages.normalized3("sv") == "swe")
        #expect(Languages.normalized3("ger") == "deu")
        #expect(Languages.normalized3("en-US") == "eng")
        #expect(Languages.normalized3(nil) == "und")
        #expect(Languages.srtCode("swe") == "sv")
        #expect(Languages.srtCode("nob") == "no")
        #expect(Languages.parseList("sv, en;ger x1") == ["swe", "eng", "deu"])
    }
}

@Suite struct TimeTests {
    @Test func parses() {
        #expect(TimeFormat.parse("00:55,855") == 55.855)
        #expect(TimeFormat.parse("00:52:10,512")! - 3130.512 < 0.0001)
        #expect(TimeFormat.parse("95.5") == 95.5)
        #expect(TimeFormat.parse("1:2.5:3") == nil)
        #expect(TimeFormat.parse("abc") == nil)
        #expect(TimeFormat.string(3725.5) == "1:02:05.500")
    }
}

@Suite struct SRTTests {
    let sample = """
    \u{FEFF}1
    00:00:01,000 --> 00:00:02,500
    <font color="#ffffff">Hej</font> {\\an8}världen

    2
    00:00:10,000 --> 00:00:12,000
    Rad ett
    Rad två

    """

    @Test func parseAndFormat() {
        let cues = SRT.parse(sample)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0 && cues[0].end == 2.5)
        #expect(cues[1].text == "Rad ett\nRad två")
        #expect(SRT.cleanTags(cues[0].text) == "Hej världen")
        #expect(SRT.format(cues).contains("00:00:10,000 --> 00:00:12,000"))
    }
}

@Suite struct CutTests {
    let keyframes: [Double] = stride(from: 0.0, through: 100, by: 2).map { $0 }

    @Test func segmentsAndSnapping() {
        let plan = CutPlan(removals: [TimeRange(0, 10), TimeRange(40, 51)], duration: 100,
                           keyframes: keyframes, precise: false)
        #expect(plan.segments.count == 2)
        #expect(plan.segments[0].start == 10 && plan.segments[0].end == 40)
        // 51 is not a keyframe → copy starts at 50
        #expect(plan.segments[1].start == 50)
        #expect(plan.misalignedSegments.count == 1)
        #expect(abs(plan.outputDuration - 80) < 0.001)
    }

    @Test func preciseKeepsRequestedStart() {
        let plan = CutPlan(removals: [TimeRange(0, 11)], duration: 100, keyframes: keyframes, precise: true)
        #expect(plan.segments[0].start == 11)
    }

    @Test func mapsSubtitles() {
        let plan = CutPlan(removals: [TimeRange(0, 10), TimeRange(40, 50)], duration: 100,
                           keyframes: keyframes, precise: false)
        #expect(plan.map(SubtitleCue(start: 5, end: 6, text: "x")).isEmpty)
        #expect(plan.map(SubtitleCue(start: 12, end: 14, text: "x")) == [SubtitleCue(start: 2, end: 4, text: "x")])
        // spans the second cut → clipped
        #expect(plan.map(SubtitleCue(start: 39, end: 41, text: "x")) == [SubtitleCue(start: 29, end: 30, text: "x")])
        #expect(plan.map(SubtitleCue(start: 55, end: 56, text: "x")) == [SubtitleCue(start: 35, end: 36, text: "x")])
    }

    @Test func normalizesOverlaps() {
        let n = Cuts.normalize([TimeRange(5, 10), TimeRange(8, 20), TimeRange(-3, 1), TimeRange(90, 200)], duration: 100)
        #expect(n == [TimeRange(0, 1), TimeRange(5, 20), TimeRange(90, 100)])
        #expect(Cuts.nearestKeyframe(to: 4.9, in: keyframes) == 4)
        #expect(Cuts.keyframe(atOrBefore: 5.9, in: keyframes) == 4)
        #expect(Cuts.nextKeyframe(after: 4, in: keyframes) == 6)
        #expect(Cuts.previousKeyframe(before: 4, in: keyframes) == 2)
        #expect(Cuts.indexRange(of: keyframes, from: 3, to: 8) == 2..<5)
        #expect(Cuts.indexRange(of: keyframes, from: 200, to: 300).isEmpty)
        #expect(Cuts.nearestKeyframeIndex(to: 5.2, in: keyframes) == 3)
    }
}

// MARK: - End to end (needs ffmpeg + mkvtoolnix from Homebrew)

@Suite(.serialized) struct EndToEndTests {
    let tools = ToolPaths.locate()

    func makeSample(in dir: URL, ext: String) async throws -> URL {
        let ffmpeg = try #require(tools.ffmpeg)
        let srt1 = dir.appendingPathComponent("a.srt"), srt2 = dir.appendingPathComponent("b.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\n<font color=\"red\">Ett</font>\n\n2\n00:00:13,000 --> 00:00:14,000\nTretton\n\n"
            .write(to: srt1, atomically: true, encoding: .utf8)
        try "1\n00:00:05,000 --> 00:00:06,000\nFive\n\n".write(to: srt2, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("prov.\(ext)")
        let subCodec = ext == "mkv" ? "srt" : "mov_text"
        let args = ["-hide_banner", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=20",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=20",
                    "-f", "lavfi", "-i", "sine=frequency=880:duration=20",
                    "-i", srt1.path, "-i", srt2.path,
                    "-map", "0", "-map", "1", "-map", "2", "-map", "3", "-map", "4",
                    "-c:v", "libx264", "-g", "25", "-keyint_min", "25", "-sc_threshold", "0", "-bf", "0",
                    "-c:a", "aac", "-c:s", subCodec,
                    "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=ger",
                    "-metadata:s:s:0", "language=swe", "-metadata:s:s:1", "language=eng",
                    "-metadata", "title=Skräptitel", out.path]
        let r = try await ProcessRunner.run(ffmpeg, args)
        #expect(r.status == 0, "\(r.stderr)")
        return out
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vr-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test(arguments: ["mkv", "mp4"]) func cutsCleansAndExtracts(ext: String) async throws {
        guard tools.hasFFmpeg else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSample(in: dir, ext: ext)
        let info = try await Probe.mediaInfo(src, tools: tools)
        #expect(info.audioStreams.count == 2 && info.subtitleStreams.count == 2)
        let kfs = try await Probe.keyframes(src, info: info, tools: tools)
        #expect(kfs.contains { abs($0 - 2) < 0.01 } && kfs.contains { abs($0 - 12) < 0.01 })

        var options = ProcessingOptions()
        options.convertToMKV = true
        options.trashOriginalAfterConversion = false
        let job = ProcessingJob(
            input: src, info: info, keyframes: kfs,
            keepAudio: [info.audioStreams[0].index],
            selectedSubtitles: Set(info.subtitleStreams.map(\.index)),
            languages: [info.subtitleStreams[1].index: "fra"],
            removals: [TimeRange(0, 2), TimeRange(10, 12)], options: options)
        let log = LogBox()
        let result = try await Processor(tools: tools).process(job, log: { log.add($0) }, progress: { _ in })
        #expect(result.skippedReason == nil, "\(log.text)")
        #expect(result.output.pathExtension == "mkv")

        let outInfo = try await Probe.mediaInfo(result.output, tools: tools)
        #expect(abs(outInfo.duration - 16) < 0.3, "duration \(outInfo.duration)\n\(log.text)")
        #expect(outInfo.audioStreams.count == 1)
        #expect(outInfo.audioStreams.first?.normalizedLanguage == "eng")
        #expect(outInfo.subtitleStreams.isEmpty)

        let sv = dir.appendingPathComponent("prov.sv.srt")
        let fr = dir.appendingPathComponent("prov.fr.srt")
        let svCues = SRT.parse(try String(contentsOf: sv, encoding: .utf8))
        // "Ett" (1–2 s) was cut away; "Tretton" 13 s → 13 − 2 − 2 = 9 s
        #expect(svCues.count == 1)
        #expect(abs(svCues[0].start - 9) < 0.01)
        #expect(!svCues[0].text.contains("font"))
        let frCues = SRT.parse(try String(contentsOf: fr, encoding: .utf8))
        #expect(abs(frCues[0].start - 3) < 0.01)
    }

    @Test func cutBetweenKeyframesReencodes() async throws {
        guard tools.hasFFmpeg else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSample(in: dir, ext: "mkv")
        let info = try await Probe.mediaInfo(src, tools: tools)
        let kfs = try await Probe.keyframes(src, info: info, tools: tools)
        var options = ProcessingOptions()
        options.extractSubtitles = true
        // 2.5 s is between the keyframes at 2 and 3 → must re-encode and start exactly at 2.5
        let job = ProcessingJob(input: src, info: info, keyframes: kfs,
                                keepAudio: Set(info.audioStreams.map(\.index)),
                                selectedSubtitles: [info.subtitleStreams[1].index],
                                removals: [TimeRange(0, 2.5), TimeRange(10.5, 12.3)], options: options)
        let log = LogBox()
        let result = try await Processor(tools: tools).process(job, log: { log.add($0) }, progress: { _ in })
        #expect(log.text.contains("re-encoded"), "\(log.text)")
        let outInfo = try await Probe.mediaInfo(result.output, tools: tools)
        #expect(abs(outInfo.duration - 15.7) < 0.1, "duration \(outInfo.duration)")
        // picture and sound both start at the beginning
        for s in outInfo.streams { #expect(s.startTime < 0.05, "\(s.kind) starts at \(s.startTime)") }
        let cues = SRT.parse(try String(contentsOf: dir.appendingPathComponent("prov.en.srt"), encoding: .utf8))
        #expect(abs(cues[0].start - 2.5) < 0.01)
    }

    @Test func keepsFormatWithoutCut() async throws {
        guard tools.hasFFmpeg else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSample(in: dir, ext: "mp4")
        let info = try await Probe.mediaInfo(src, tools: tools)
        var options = ProcessingOptions()
        options.convertToMKV = false
        options.extractSubtitles = false
        let job = ProcessingJob(input: src, info: info, keepAudio: Set(info.audioStreams.map(\.index)),
                                selectedSubtitles: [], options: options)
        let result = try await Processor(tools: tools).process(job, log: { _ in }, progress: { _ in })
        #expect(result.output == src)
        let outInfo = try await Probe.mediaInfo(src, tools: tools)
        #expect(outInfo.subtitleStreams.isEmpty && outInfo.audioStreams.count == 2)
        #expect(abs(outInfo.duration - 20) < 0.3)
    }

    @Test func languageOnlyMKV() async throws {
        guard tools.hasMKVToolNix else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSample(in: dir, ext: "mkv")
        let info = try await Probe.mediaInfo(src, tools: tools)
        var options = ProcessingOptions()
        options.languageOnly = true
        let job = ProcessingJob(input: src, info: info, keepAudio: [], selectedSubtitles: [],
                                languages: [info.audioStreams[1].index: "swe"], options: options)
        _ = try await Processor(tools: tools).process(job, log: { _ in }, progress: { _ in })
        let outInfo = try await Probe.mediaInfo(src, tools: tools)
        #expect(outInfo.audioStreams[1].normalizedLanguage == "swe")
        #expect(outInfo.subtitleStreams.count == 2)
    }

    @Test func dryRunChangesNothing() async throws {
        guard tools.hasFFmpeg else { return }
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try await makeSample(in: dir, ext: "mp4")
        let info = try await Probe.mediaInfo(src, tools: tools)
        let job = ProcessingJob(input: src, info: info, keepAudio: [info.audioStreams[0].index],
                                selectedSubtitles: Set(info.subtitleStreams.map(\.index)),
                                removals: [TimeRange(0, 4)])
        let log = LogBox()
        _ = try await Processor(tools: tools).process(job, dryRun: true, log: { log.add($0) }, progress: { _ in })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.hasSuffix(".mkv") })
        #expect(log.text.contains("ffmpeg"))
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    func add(_ e: LogEntry) { lock.lock(); entries.append(e); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return entries.map(\.text).joined(separator: "\n") }
}
