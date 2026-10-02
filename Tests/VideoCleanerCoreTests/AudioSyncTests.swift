// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import VideoCleanerCore

/// Synthetic "film sound": shared music & effects (noise bursts) plus a voice track (tone bursts) that differs
/// between the original and the dub — the situation the synchronizer is built for.
struct SyntheticSound {
    struct Event { let time: Double; let length: Double; let amp: Float; let freq: Double }
    let effects: [Event]
    let voice: [Event]

    init(duration: Double, effectsSeed: UInt64, voiceSeed: UInt64) {
        effects = Self.events(duration: duration, seed: effectsSeed, every: 0.8, freq: 0)
        voice = Self.events(duration: duration, seed: voiceSeed, every: 0.45, freq: 1)
    }

    static func events(duration: Double, seed: UInt64, every: Double, freq: Double) -> [Event] {
        var rng = seed
        func next() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(rng >> 11) / Double(1 << 53)
        }
        var out: [Event] = []
        var t = 0.0
        while t < duration {
            t += every * (0.3 + 1.4 * next())
            out.append(Event(time: t, length: 0.05 + 0.35 * next(), amp: Float(0.2 + 0.8 * next()),
                             freq: freq == 0 ? 0 : 150 + 400 * next()))
        }
        return out
    }

    /// Deterministic noise in [-1, 1] for a moment in time (so stretched copies stay comparable).
    static func noise(_ t: Double) -> Float {
        var x = UInt64(bitPattern: Int64((t * 8000).rounded())) &* 0x9E3779B97F4A7C15
        x ^= x >> 29; x = x &* 0xBF58476D1CE4E5B9; x ^= x >> 32
        return Float(Double(x >> 11) / Double(1 << 53)) * 2 - 1
    }

    func value(at t: Double) -> Float {
        var v: Float = 0
        for e in effects where t >= e.time && t < e.time + e.length {
            v += e.amp * Self.noise(t) * Float(exp(-(t - e.time) * 6))
        }
        for e in voice where t >= e.time && t < e.time + e.length {
            v += 0.5 * e.amp * Float(sin(2 * .pi * e.freq * t))
        }
        return v * 0.4
    }

    /// Samples at 8 kHz of the original film sound.
    func render(seconds: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * 8000))
        Self.addEffects(effects, into: &out, filmTime: { $0 }, sampleOf: { $0 })
        Self.addVoice(voice, into: &out)
        return out
    }

    /// Adds effect bursts. A sample at its own time s carries film time filmTime(s); sampleOf(t) is the inverse.
    static func addEffects(_ events: [Event], into out: inout [Float], filmTime: (Double) -> Double,
                           sampleOf: (Double) -> Double) {
        for e in events {
            let first = max(0, Int((sampleOf(e.time) * 8000).rounded(.up)))
            let last = min(out.count - 1, Int((sampleOf(e.time + e.length) * 8000).rounded(.down)))
            guard first <= last else { continue }
            for i in first...last {
                let t = filmTime(Double(i) / 8000)
                out[i] += 0.4 * e.amp * noise(t) * Float(exp(-(t - e.time) * 6))
            }
        }
    }

    static func addVoice(_ events: [Event], into out: inout [Float]) {
        for e in events {
            let first = max(0, Int(e.time * 8000)), last = min(out.count - 1, Int((e.time + e.length) * 8000))
            guard first <= last else { continue }
            for i in first...last {
                let s = Double(i) / 8000
                out[i] += 0.2 * e.amp * Float(sin(2 * .pi * e.freq * s))
            }
        }
    }
}

func onsetCurve(_ samples: [Float]) -> [Float] {
    let acc = EnergyAccumulator(samplesPerFrame: AudioSync.samplesPerFrame)
    samples.withUnsafeBufferPointer { acc.add(Data(buffer: $0)) }
    return AudioSync.onsets(fromEnergies: acc.finish())
}

func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int = 8000) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32000))) }
    try d.write(to: url)
}

@Suite struct AudioSyncTests {
    let film = SyntheticSound(duration: 330, effectsSeed: 7, voiceSeed: 11)
    let dubVoice = SyntheticSound(duration: 330, effectsSeed: 7, voiceSeed: 99)

    /// The dub carries the same effects but other voices.
    /// A dub sample at its own time s carries film time s·stretch + offset (= where it must play).
    func dub(seconds: Double, offset: Double, stretch: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(seconds * 8000))
        SyntheticSound.addEffects(film.effects, into: &out, filmTime: { $0 * stretch + offset },
                                  sampleOf: { ($0 - offset) / stretch })
        SyntheticSound.addVoice(dubVoice.voice, into: &out)
        return out
    }

    @Test func crossCorrelationFindsKnownLag() {
        var a = [Float](repeating: 0, count: 1000), b = [Float](repeating: 0, count: 1000)
        for i in stride(from: 3, to: 900, by: 37) { b[i] = 1; a[i + 42] = 1 }
        let m = AudioSync.bestLag(a, b, maxLag: 200)
        #expect(m != nil && abs(m!.lag - 42) < 0.01)
        let m2 = AudioSync.bestLag(b, a, maxLag: 200)
        #expect(m2 != nil && abs(m2!.lag + 42) < 0.01)
    }

    @Test func findsOffset() throws {
        let ref = onsetCurve(film.render(seconds: 300))
        // The dub's sound at its own time s belongs at film time s + 3.217
        let cand = onsetCurve(dub(seconds: 300, offset: 3.217, stretch: 1))
        let r = try AudioSync.analyze(reference: ref, candidate: cand)
        #expect(abs(r.offset - 3.217) < 0.012, "offset \(r.offset)")
        #expect(r.stretch == 1)
        #expect(r.isReliable, "confidence \(r.confidence)")
        #expect(r.isConsistent, "spread \(r.spread)")
    }

    @Test func findsPALSpeedDifference() throws {
        let pal = 25 / (24000.0 / 1001)
        let ref = onsetCurve(film.render(seconds: 300))
        // A PAL dub runs 4.27 % fast: its sample at s carries film time s·pal − 1.5, i.e. movie = s·pal − 1.5
        let cand = onsetCurve(dub(seconds: 288, offset: -1.5, stretch: pal))
        let r = try AudioSync.analyze(reference: ref, candidate: cand)
        #expect(abs(r.stretch - pal) < 0.0001, "stretch \(r.stretch)")
        #expect(abs(r.offset - -1.5) < 0.03, "offset \(r.offset)")
        #expect(r.isConsistent, "spread \(r.spread)")
    }

    @Test func rejectsUnrelatedAudio() {
        let ref = onsetCurve(film.render(seconds: 120))
        let other = onsetCurve(SyntheticSound(duration: 130, effectsSeed: 1234, voiceSeed: 5).render(seconds: 120))
        #expect(throws: AudioSyncError.self) { try AudioSync.analyze(reference: ref, candidate: other) }
    }

    /// Whole chain: find the offset with ffmpeg-decoded files, add the track with that offset, and check that
    /// the added track is in sync with the film's own track afterwards.
    @Test func addedTrackEndsUpInSync() async throws {
        let tools = ToolPaths.locate()
        guard let ffmpeg = tools.ffmpeg else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["KEEP_TEST_FILES"] == nil { try? FileManager.default.removeItem(at: dir) } else { print("TESTDIR \(dir.path)") } }

        let seconds = 150.0
        let filmWav = dir.appendingPathComponent("film.wav"), dubWav = dir.appendingPathComponent("dub.wav")
        try writeWAV(film.render(seconds: seconds), to: filmWav)
        // The dub file has 2.75 s of extra sound before the film starts (e.g. a TV channel ident)
        try writeWAV(dub(seconds: seconds, offset: -2.75, stretch: 1), to: dubWav)
        let movie = dir.appendingPathComponent("movie.mkv"), dubFile = dir.appendingPathComponent("dub.ac3")
        var r = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=\(Int(seconds))", "-i", filmWav.path,
            "-map", "0", "-map", "1", "-c:v", "libx264", "-g", "25", "-c:a", "aac", "-ar", "48000",
            "-metadata:s:a:0", "language=eng", movie.path])
        #expect(r.status == 0, "\(r.stderr)")
        r = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-i", dubWav.path,
                                                 "-c:a", "ac3", "-ar", "48000", "-b:a", "192k", dubFile.path])
        #expect(r.status == 0, "\(r.stderr)")

        let info = try await Probe.mediaInfo(movie, tools: tools)
        let dubInfo = try await Probe.mediaInfo(dubFile, tools: tools)
        let sync = try await AudioSync.synchronize(reference: movie, referenceStream: info.audioStreams[0].index,
                                                   referenceDuration: info.duration, candidate: dubFile,
                                                   candidateStream: dubInfo.audioStreams[0].index,
                                                   candidateDuration: dubInfo.duration, tools: tools)
        #expect(abs(sync.offset - -2.75) < 0.04, "offset \(sync.offset)")  // the dub's first 2.75 s come before the film
        #expect(sync.stretch == 1)

        var track = AddedAudio(source: dubFile, stream: dubInfo.audioStreams[0], sourceDuration: dubInfo.duration)
        track.language = "swe"; track.title = "Svenska"; track.isDefault = true
        track.offset = sync.offset; track.stretch = sync.stretch
        var options = ProcessingOptions(); options.extractSubtitles = false
        let job = ProcessingJob(input: movie, info: info, keepAudio: [info.audioStreams[0].index], selectedSubtitles: [],
                                removals: [TimeRange(0, 10)], addedAudio: [track], options: options)
        let log = LogBox()
        let result = try await Processor(tools: tools).process(job, log: { log.add($0) }, progress: { _ in })
        let out = try await Probe.mediaInfo(result.output, tools: tools)
        #expect(out.audioStreams.count == 2, "\(log.text)")
        let added = try #require(out.audioStreams.last)
        #expect(added.normalizedLanguage == "swe" && added.title == "Svenska" && added.isDefault)
        #expect(out.audioStreams.first?.isDefault == false)
        #expect(abs(out.duration - (seconds - 10)) < 0.2, "duration \(out.duration)")

        // After processing, the Swedish track must line up with the film's own track
        let check = try await AudioSync.synchronize(reference: result.output, referenceStream: out.audioStreams[0].index,
                                                    referenceDuration: out.duration, candidate: result.output,
                                                    candidateStream: added.index, candidateDuration: out.duration, tools: tools)
        #expect(abs(check.offset) < 0.04, "remaining offset \(check.offset)\n\(log.text)")
    }

    @Test func copiesTrackLosslesslyWhenOnlyShifted() async throws {
        let tools = ToolPaths.locate()
        guard let ffmpeg = tools.ffmpeg else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let movie = dir.appendingPathComponent("m.mp4"), extra = dir.appendingPathComponent("x.ac3")
        _ = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "testsrc=size=160x120:rate=25:duration=12", "-f", "lavfi", "-i", "sine=f=440:duration=12",
            "-c:v", "libx264", "-c:a", "aac", movie.path])
        _ = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "sine=f=880:duration=8:sample_rate=48000", "-c:a", "ac3", extra.path])
        let info = try await Probe.mediaInfo(movie, tools: tools)
        let xInfo = try await Probe.mediaInfo(extra, tools: tools)
        var track = AddedAudio(source: extra, stream: xInfo.audioStreams[0], sourceDuration: xInfo.duration)
        track.offset = 2.5
        var options = ProcessingOptions(); options.convertToMKV = false
        let job = ProcessingJob(input: movie, info: info, keepAudio: Set(info.audioStreams.map(\.index)),
                                selectedSubtitles: [], addedAudio: [track], options: options)
        let log = LogBox()
        let result = try await Processor(tools: tools).process(job, log: { log.add($0) }, progress: { _ in })
        #expect(log.text.contains("copied"), "\(log.text)")
        let out = try await Probe.mediaInfo(result.output, tools: tools)
        #expect(result.output.pathExtension == "mp4")
        #expect(out.audioStreams.count == 2)
        #expect(out.audioStreams[1].codec == "ac3")
        #expect(abs(out.audioStreams[1].startTime - 2.5) < 0.04, "start \(out.audioStreams[1].startTime)")
    }
}
