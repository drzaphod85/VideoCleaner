// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The processing pipeline — a native port of clean_and_extract_subs.sh:
//  1. Extract selected text subtitles to .srt (mkvextract for SubRip in MKV, otherwise ffmpeg),
//     clean <font>/{\an} tags and shift the timing to match the cut video.
//  2. Write a clean copy without subtitles (or with the selected ones), without re-encoding:
//     mkvmerge for MKV → MKV without cuts, otherwise ffmpeg -c copy. Cuts are made at keyframes;
//     several kept segments are written separately and joined with ffmpeg's concat demuxer.
//  3. Set language tags, remove audio tracks (never all of them), optionally convert to MKV.
//  4. "Language only" mode: mkvpropedit in place (MKV) or an ffmpeg metadata remux.

import Foundation

public struct ProcessingOptions: Codable, Sendable, Equatable {
    public var convertToMKV = true
    public var trashOriginalAfterConversion = true
    public var extractSubtitles = true
    public var removeSubtitlesFromVideo = true
    public var cleanSubtitleTags = true
    public var tagForcedAndSDH = true
    public var outputDirectory: String?
    public var languageOnly = false
    public var useMKVToolNix = true

    public init() {}
}

public struct ProcessingJob: Sendable {
    public var input: URL
    public var info: MediaInfo
    public var keyframes: [Double]
    /// Stream indexes of audio tracks to keep.
    public var keepAudio: Set<Int>
    /// Stream indexes of selected subtitle tracks (extracted to .srt and/or kept in the file).
    public var selectedSubtitles: Set<Int>
    /// New language per stream index (three-letter code). Only changed tracks.
    public var languages: [Int: String]
    public var removals: [TimeRange]
    /// Always re-encode the video when cutting. Without it the video is only re-encoded when a kept part
    /// starts between keyframes (then automatically, so every cut lands exactly where it was placed).
    public var preciseCut: Bool
    public var options: ProcessingOptions

    public init(input: URL, info: MediaInfo, keyframes: [Double] = [], keepAudio: Set<Int>,
                selectedSubtitles: Set<Int>, languages: [Int: String] = [:], removals: [TimeRange] = [],
                preciseCut: Bool = false, options: ProcessingOptions = ProcessingOptions()) {
        self.input = input; self.info = info; self.keyframes = keyframes; self.keepAudio = keepAudio
        self.selectedSubtitles = selectedSubtitles; self.languages = languages; self.removals = removals
        self.preciseCut = preciseCut; self.options = options
    }
}

public struct ProcessingResult: Sendable {
    public var output: URL
    public var subtitleFiles: [URL] = []
    public var skippedReason: String?
    public var trashedOriginal = false
}

public struct LogEntry: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable { case step, info, warning, error, success, command }
    public let id = UUID()
    public let kind: Kind
    public let text: String
    public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
}

public enum ProcessingError: LocalizedError {
    case missingTool(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let t): return L("%@ is missing", t)
        case .failed(let m): return m
        }
    }
}

public final class Processor: Sendable {
    public let tools: ToolPaths
    public init(tools: ToolPaths) { self.tools = tools }

    /// Runs the job. With `dryRun` nothing is changed; the planned commands are logged instead.
    public func process(_ job: ProcessingJob, dryRun: Bool = false,
                        log: @escaping @Sendable (LogEntry) -> Void,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> ProcessingResult {
        let run = Run(job: job, tools: tools, dryRun: dryRun, log: log, progress: progress)
        defer { run.cleanup() }
        return try await run.execute()
    }
}

private final class Run: @unchecked Sendable {
    let job: ProcessingJob
    let tools: ToolPaths
    let dryRun: Bool
    let logHandler: @Sendable (LogEntry) -> Void
    let progressHandler: @Sendable (Double) -> Void
    let fm = FileManager.default
    var tempItems: [URL] = []
    /// Re-encode the video (frame-exact cuts). Decided in execute().
    var reencode = false
    var keyframes: [Double] = []

    init(job: ProcessingJob, tools: ToolPaths, dryRun: Bool, log: @escaping @Sendable (LogEntry) -> Void,
         progress: @escaping @Sendable (Double) -> Void) {
        self.job = job; self.tools = tools; self.dryRun = dryRun
        self.logHandler = log; self.progressHandler = progress
    }

    var input: URL { job.input }
    var info: MediaInfo { job.info }
    var opts: ProcessingOptions { job.options }
    var stem: String { input.deletingPathExtension().lastPathComponent }
    var inExt: String { input.pathExtension.lowercased() }
    var useMKVToolNix: Bool { opts.useMKVToolNix && tools.hasMKVToolNix && inExt == "mkv" }

    func log(_ kind: LogEntry.Kind, _ text: String) { logHandler(LogEntry(kind, text)) }

    static let common = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error"]
    static let progressArgs = ["-progress", "pipe:1", "-nostats"]
    static let mp4Family: Set<String> = ["mp4", "m4v", "mov"]

    func cleanup() {
        for url in tempItems.reversed() { try? fm.removeItem(at: url) }
        tempItems = []
    }

    // MARK: - Pipeline

    func execute() async throws -> ProcessingResult {
        guard let ffmpeg = tools.ffmpeg, tools.ffprobe != nil else {
            throw ProcessingError.missingTool(L("ffmpeg/ffprobe — install with: brew install ffmpeg"))
        }
        guard fm.fileExists(atPath: input.path) else { throw ProcessingError.failed(L("File not found: %@", input.path)) }
        if dryRun { log(.info, L("Dry run — no files are changed")) }

        if !dryRun, await isFileGrowing() {
            log(.warning, L("The file is still being written (size is changing) — skipping"))
            return ProcessingResult(output: input, skippedReason: L("The file is still being written"))
        }

        if opts.languageOnly { return try await languageOnly(ffmpeg: ffmpeg) }

        guard let video = info.primaryVideo else { throw ProcessingError.failed(L("No video found — skipping")) }

        let outExt = opts.convertToMKV ? "mkv" : inExt
        let outIsMKV = outExt == "mkv"
        let outDir = opts.outputDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? input.deletingLastPathComponent()
        let outURL = outDir.appendingPathComponent("\(stem).\(outExt)")
        let sameFile = outURL.standardizedFileURL.path == input.standardizedFileURL.path
        let converting = outExt != inExt

        if converting { log(.info, L("Format .%@ → converting (remux) to .mkv", inExt)) }
        if !sameFile && fm.fileExists(atPath: outURL.path) {
            log(.warning, L("The target already exists: %@ — skipping (delete or move it first)", outURL.lastPathComponent))
            return ProcessingResult(output: input, skippedReason: L("The target already exists"))
        }
        if !dryRun && opts.outputDirectory != nil {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        }

        // Audio: never remove every track
        var audio = info.audioStreams.filter { job.keepAudio.contains($0.index) }
        if audio.isEmpty && !info.audioStreams.isEmpty {
            log(.warning, L("All audio tracks were deselected — keeping all of them"))
            audio = info.audioStreams
        }
        for a in info.audioStreams where !audio.contains(a) {
            log(.step, L("Removing audio track a%lld (%@, language=%@)", a.ordinal + 1, a.codec, a.normalizedLanguage))
        }

        // Subtitles kept inside the video
        var keptSubs: [StreamInfo] = []
        if !opts.removeSubtitlesFromVideo {
            for s in info.subtitleStreams where job.selectedSubtitles.contains(s.index) {
                if !outIsMKV && !s.isTextSubtitle {
                    log(.warning, L("Image subtitle s%lld (%@) cannot be kept in .%@ — removed", s.ordinal + 1, s.codec, outExt))
                } else {
                    keptSubs.append(s)
                }
            }
        }

        // Cuts
        keyframes = job.keyframes
        if !job.removals.isEmpty && keyframes.isEmpty {
            log(.info, L("Reading keyframes…"))
            keyframes = (try? await Probe.keyframes(input, info: info, tools: tools)) ?? []
        }
        var plan = CutPlan(removals: job.removals, duration: info.duration, keyframes: keyframes,
                           precise: job.preciseCut)
        reencode = job.preciseCut && plan.isCutting
        if plan.isCutting && !reencode && !keyframes.isEmpty && !plan.misalignedSegments.isEmpty {
            // A kept part starts between keyframes: stream copy cannot start there, so re-encode for an exact cut
            for seg in plan.misalignedSegments {
                log(.warning, L("The cut at %@ is between keyframes — the video is re-encoded so the cut is exact (takes longer)",
                                TimeFormat.string(seg.requestedStart)))
            }
            reencode = true
            plan = CutPlan(removals: job.removals, duration: info.duration, keyframes: keyframes, precise: true)
        }
        if plan.isCutting {
            guard !plan.segments.isEmpty else { throw ProcessingError.failed(L("The whole file is marked as removed")) }
            let removed = plan.removals.map { "\(TimeFormat.string($0.start))–\(TimeFormat.string($0.end))" }
            log(.step, (reencode ? L("✂︎ Cutting away: %@ (frame-exact, re-encoding video)", removed.joined(separator: ", "))
                                 : L("✂︎ Cutting away: %@ (at keyframes, no re-encoding)", removed.joined(separator: ", "))))
            log(.info, L("New length: %@ (was %@)", TimeFormat.string(plan.outputDuration), TimeFormat.string(info.duration)))
        }

        // 1) Subtitles → .srt
        var result = ProcessingResult(output: outURL)
        let textSubs = opts.extractSubtitles
            ? info.subtitleStreams.filter { job.selectedSubtitles.contains($0.index) }
            : []
        for s in textSubs where !s.isTextSubtitle {
            log(.info, L("Skipping s%lld (image-based %@, cannot become .srt)", s.ordinal + 1, s.codec))
        }
        let extractable = textSubs.filter(\.isTextSubtitle)
        let remuxRange: ClosedRange<Double> = extractable.isEmpty ? 0...1 : 0.1...1
        if !extractable.isEmpty {
            result.subtitleFiles = try await extractSubtitles(extractable, plan: plan, outDir: outDir, ffmpeg: ffmpeg)
        }
        progressHandler(remuxRange.lowerBound)

        // 2) Clean copy
        let tmp = outDir.appendingPathComponent(".\(stem).videocleaner-\(UUID().uuidString.prefix(8)).\(outExt)")
        tempItems.append(tmp)
        log(.step, keptSubs.isEmpty ? L("Creating clean copy without subtitles → %@", outURL.lastPathComponent)
                                  : L("Creating clean copy → %@", outURL.lastPathComponent))

        let useMKVMerge = useMKVToolNix && outIsMKV && !plan.isCutting
        if useMKVMerge {
            try await remuxWithMKVMerge(video: video, audio: audio, subs: keptSubs, to: tmp, range: remuxRange)
        } else {
            try await remuxWithFFmpeg(ffmpeg: ffmpeg, video: video, audio: audio, subs: keptSubs, plan: plan,
                                      outExt: outExt, to: tmp, range: remuxRange)
        }

        if dryRun {
            if converting && opts.trashOriginalAfterConversion {
                log(.info, L("Would move the original to the Trash: %@", input.lastPathComponent))
            }
            return result
        }

        // 3) Put the result in place
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw ProcessingError.failed(L("The result file is empty — the original is untouched")) }
        if sameFile {
            do {
                _ = try fm.replaceItemAt(outURL, withItemAt: tmp)
            } catch {
                try fm.removeItem(at: outURL)
                try fm.moveItem(at: tmp, to: outURL)
            }
        } else {
            try fm.moveItem(at: tmp, to: outURL)
        }
        tempItems.removeAll { $0 == tmp }

        if converting && opts.trashOriginalAfterConversion && !sameFile {
            do {
                try fm.trashItem(at: input, resultingItemURL: nil)
                result.trashedOriginal = true
                log(.step, L("Moved the original to the Trash: %@", input.lastPathComponent))
            } catch {
                log(.warning, L("Could not move the original to the Trash: %@", error.localizedDescription))
            }
        }
        progressHandler(1)
        log(.success, L("Done: %@", outURL.lastPathComponent))
        return result
    }

    // MARK: - Language only

    func languageOnly(ffmpeg: URL) async throws -> ProcessingResult {
        let changes = (info.audioStreams + info.subtitleStreams).compactMap { s -> (StreamInfo, String)? in
            job.languages[s.index].map { (s, $0) }
        }
        guard !changes.isEmpty else {
            log(.info, L("No languages to change — skipping"))
            return ProcessingResult(output: input, skippedReason: L("No languages to change"))
        }
        let desc = changes.map { "\($0.0.kind == .audio ? "a" : "s")\($0.0.ordinal + 1)=\($0.1)" }.joined(separator: " ")
        if useMKVToolNix, let propedit = tools.mkvpropedit {
            log(.step, L("Setting languages in place (mkvpropedit): %@", desc))
            var args = [input.path]
            for (s, lang) in changes {
                args += ["--edit", "track:\(s.kind == .audio ? "a" : "s")\(s.ordinal + 1)", "--set", "language=\(lang)"]
            }
            let r = try await exec(propedit, args)
            if r.status >= 2 { throw ProcessingError.failed(L("mkvpropedit failed: %@", r.stdout + r.stderr)) }
        } else {
            log(.step, L("Setting languages (ffmpeg metadata remux): %@", desc))
            let tmp = input.deletingLastPathComponent()
                .appendingPathComponent(".\(stem).videocleaner-\(UUID().uuidString.prefix(8)).\(inExt)")
            tempItems.append(tmp)
            var args = Self.common + Self.progressArgs + ["-i", input.path, "-map", "0", "-dn", "-c", "copy"]
            for (s, lang) in changes {
                args += ["-metadata:s:\(s.kind == .audio ? "a" : "s"):\(s.ordinal)", "language=\(lang)"]
            }
            args += ["-strict", "-2", tmp.path]
            let r = try await exec(ffmpeg, args, range: 0...1, expected: info.duration)
            guard r.status == 0 else { throw ProcessingError.failed(L("ffmpeg failed: %@", r.stderr)) }
            if !dryRun {
                _ = try fm.replaceItemAt(input, withItemAt: tmp)
                tempItems.removeAll { $0 == tmp }
            }
        }
        if !dryRun { log(.success, L("Languages set")) }
        progressHandler(1)
        return ProcessingResult(output: input)
    }

    // MARK: - Subtitles

    func finalLanguage(_ s: StreamInfo) -> String { job.languages[s.index] ?? s.normalizedLanguage }

    func extractSubtitles(_ subs: [StreamInfo], plan: CutPlan, outDir: URL, ffmpeg: URL) async throws -> [URL] {
        struct Target { let stream: StreamInfo; let final: URL; let raw: URL }
        let work = fm.temporaryDirectory.appendingPathComponent("VideoCleaner-\(UUID().uuidString)", isDirectory: true)
        if !dryRun { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
        tempItems.append(work)

        var used = Set<String>()
        let targets: [Target] = subs.map { s in
            var name = "\(stem).\(Languages.srtCode(finalLanguage(s)))"
            if opts.tagForcedAndSDH {
                if s.isForced { name += ".forced" }
                if s.isHearingImpaired { name += ".sdh" }
            }
            var url = outDir.appendingPathComponent("\(name).srt")
            if fm.fileExists(atPath: url.path) || used.contains(url.path) {
                url = outDir.appendingPathComponent("\(name).\(s.ordinal).srt")
            }
            used.insert(url.path)
            return Target(stream: s, final: url, raw: work.appendingPathComponent("s\(s.index).srt"))
        }

        var viaMKV = targets.filter { useMKVToolNix && ["subrip", "srt"].contains($0.stream.codec) }
        var viaFF = targets.filter { t in !viaMKV.contains { $0.stream.index == t.stream.index } }
        for t in viaFF {
            log(.step, L("Extracting (ffmpeg): s%lld %@, language=%@ → %@", t.stream.ordinal + 1, t.stream.codec,
                        Languages.srtCode(finalLanguage(t.stream)), t.final.lastPathComponent))
        }

        if !viaMKV.isEmpty, let mkvextract = tools.mkvextract {
            for t in viaMKV {
                log(.step, L("Extracting (mkvextract): s%lld %@, language=%@ → %@", t.stream.ordinal + 1, t.stream.codec,
                            Languages.srtCode(finalLanguage(t.stream)), t.final.lastPathComponent))
            }
            let args = ["-q", input.path, "tracks"] + viaMKV.map { "\($0.stream.index):\($0.raw.path)" }
            let r = try await exec(mkvextract, args)
            if r.status >= 2 {
                log(.warning, L("mkvextract failed — using ffmpeg for those tracks"))
                viaFF += viaMKV
                viaMKV = []
            }
        }

        if !viaFF.isEmpty {
            var args = Self.common + ["-i", input.path]
            for t in viaFF { args += ["-map", "0:\(t.stream.index)", "-c:s", "srt", "-f", "srt", t.raw.path] }
            let r = try await exec(ffmpeg, args)
            if r.status != 0 {
                log(.warning, L("Combined extraction failed — trying track by track"))
                for t in viaFF {
                    let one = Self.common + ["-i", input.path, "-map", "0:\(t.stream.index)", "-c:s", "srt",
                                             "-f", "srt", t.raw.path]
                    let r1 = try await exec(ffmpeg, one)
                    if r1.status != 0 { log(.warning, L("Failed to extract s%lld", t.stream.ordinal + 1)) }
                }
            }
        }

        if dryRun {
            if opts.cleanSubtitleTags { log(.info, L("Would remove font/position tags from the .srt files")) }
            if plan.isCutting { log(.info, L("Would shift the subtitle timing to match the cut")) }
            return targets.map(\.final)
        }

        var written: [URL] = []
        for t in targets {
            guard let data = fm.contents(atPath: t.raw.path), !data.isEmpty else { continue }
            var cues = SRT.parse(SRT.decode(data))
            if opts.cleanSubtitleTags {
                cues = cues.map { SubtitleCue(start: $0.start, end: $0.end, text: SRT.cleanTags($0.text)) }
                    .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            if plan.isCutting { cues = cues.flatMap(plan.map) }
            if cues.isEmpty {
                log(.warning, plan.isCutting ? L("s%lld has no lines left after cutting — skipping", t.stream.ordinal + 1)
                                             : L("s%lld has no lines — skipping", t.stream.ordinal + 1))
                continue
            }
            try SRT.format(cues).write(to: t.final, atomically: true, encoding: .utf8)
            written.append(t.final)
            var notes: [String] = [L("%lld lines", cues.count)]
            if opts.cleanSubtitleTags { notes.append(L("tags removed")) }
            if plan.isCutting { notes.append(L("timing shifted")) }
            log(.info, "→ \(t.final.lastPathComponent) (\(notes.joined(separator: ", ")))")
        }
        return written
    }

    // MARK: - Remux

    func remuxWithMKVMerge(video: StreamInfo, audio: [StreamInfo], subs: [StreamInfo], to out: URL,
                           range: ClosedRange<Double>) async throws {
        guard let mkvmerge = tools.mkvmerge else { throw ProcessingError.missingTool("mkvmerge") }
        log(.info, L("MKV file → using mkvtoolnix"))
        var args = ["--gui-mode", "-o", out.path, "--video-tracks", "\(video.index)"]
        if audio.isEmpty {
            args.append("--no-audio")
        } else {
            args += ["--audio-tracks", audio.map { "\($0.index)" }.joined(separator: ",")]
            if !audio.contains(where: \.isDefault) && info.audioStreams.contains(where: \.isDefault) {
                args += ["--default-track-flag", "\(audio[0].index):1"]
            }
        }
        if subs.isEmpty {
            args.append("--no-subtitles")
        } else {
            args += ["--subtitle-tracks", subs.map { "\($0.index)" }.joined(separator: ",")]
        }
        for s in audio + subs {
            if let lang = job.languages[s.index] { args += ["--language", "\(s.index):\(lang)"] }
        }
        args += ["--no-attachments", "--no-global-tags", "--title", "", input.path]
        let r = try await exec(mkvmerge, args, range: range, mkvProgress: true)
        if r.status == 1 { log(.warning, L("mkvmerge reported warnings (continuing)")) }
        if r.status >= 2 {
            let msg = r.stdout.split(separator: "\n").filter { $0.contains("Error") || $0.contains("#GUI#error") }
            throw ProcessingError.failed(L("mkvmerge failed: %@", msg.joined(separator: " ")))
        }
    }

    /// Stream mapping, metadata and codec arguments shared by every ffmpeg remux of this job.
    func streamArgs(video: StreamInfo, audio: [StreamInfo], subs: [StreamInfo], outExt: String, cutting: Bool) -> [String] {
        let outIsMKV = outExt == "mkv"
        var a = ["-map", "0:\(video.index)"]
        for s in audio + subs { a += ["-map", "0:\(s.index)"] }
        a += ["-map_metadata", "-1", "-map_metadata:s:v:0", "0:s:\(video.index)"]
        for (pos, s) in audio.enumerated() {
            a += ["-map_metadata:s:a:\(pos)", "0:s:\(s.index)"]
            if let l = job.languages[s.index] { a += ["-metadata:s:a:\(pos)", "language=\(l)"] }
        }
        for (pos, s) in subs.enumerated() {
            a += ["-map_metadata:s:s:\(pos)", "0:s:\(s.index)"]
            if let l = job.languages[s.index] { a += ["-metadata:s:s:\(pos)", "language=\(l)"] }
        }
        a += ["-c", "copy"]
        var videoCodec = video.codec
        if reencode && cutting {
            a += encoderArgs(video: video)
            videoCodec = video.codec == "hevc" ? "hevc" : "h264"
        }
        for (pos, s) in subs.enumerated() {
            if outIsMKV && ["mov_text", "tx3g"].contains(s.codec) { a += ["-c:s:\(pos)", "srt"] }
            if !outIsMKV && s.isTextSubtitle && s.codec != "mov_text" { a += ["-c:s:\(pos)", "mov_text"] }
        }
        if Self.mp4Family.contains(outExt) && videoCodec == "hevc" { a += ["-tag:v", "hvc1"] }
        if !audio.isEmpty && !audio.contains(where: \.isDefault) && info.audioStreams.contains(where: \.isDefault) {
            a += ["-disposition:a:0", "default"]
        }
        if cutting { a += ["-map_chapters", "-1", "-avoid_negative_ts", "make_zero"] }
        a += ["-strict", "-2", "-max_muxing_queue_size", "9999"]
        return a
    }

    /// Hardware (VideoToolbox) re-encode used for frame-exact cuts.
    func encoderArgs(video: StreamInfo) -> [String] {
        let audioBits = info.audioStreams.reduce(0) { $0 + ($1.bitRate ?? 640_000) }
        let estimated = video.bitRate ?? max(2_000_000, (info.bitRate ?? 8_000_000) - audioBits)
        let bitrate = "\(Int(Double(estimated) * 1.15 / 1000))k"
        if video.codec == "hevc" {
            var a = ["-c:v", "hevc_videotoolbox", "-b:v", bitrate]
            if video.is10Bit { a += ["-profile:v", "main10"] }
            return a
        }
        var a = ["-c:v", "h264_videotoolbox", "-b:v", bitrate]
        if video.is10Bit { a += ["-pix_fmt", "yuv420p"] }
        return a
    }

    func remuxWithFFmpeg(ffmpeg: URL, video: StreamInfo, audio: [StreamInfo], subs: [StreamInfo], plan: CutPlan,
                         outExt: String, to out: URL, range: ClosedRange<Double>) async throws {
        let base = streamArgs(video: video, audio: audio, subs: subs, outExt: outExt, cutting: plan.isCutting)
        let eps = reencode ? 0 : 0.0005

        func segmentArgs(_ seg: CutPlan.Segment, output: URL) -> [String] {
            var a = Self.common + Self.progressArgs
            var seek = 0.0
            if seg.requestedStart > 0.0005 {
                seek = seg.requestedStart + eps
                if reencode {
                    // Fast input seek to the keyframe before, then an exact output-side trim. This also trims the
                    // copied audio, which would otherwise start at the keyframe (sound before the first picture).
                    let kf = Cuts.keyframe(atOrBefore: seek, in: keyframes) ?? 0
                    a += ["-ss", String(format: "%.6f", kf), "-i", input.path, "-ss", String(format: "%.6f", seek - kf)]
                } else {
                    a += ["-ss", String(format: "%.6f", seek), "-i", input.path]
                }
            } else {
                a += ["-i", input.path]
            }
            if seg.end < info.duration - 0.01 { a += ["-t", String(format: "%.6f", seg.end - seek)] }
            return a + base + [output.path]
        }

        if plan.segments.count <= 1 {
            let seg = plan.segments.first ?? CutPlan.Segment(requestedStart: 0, start: 0, end: info.duration)
            let r = try await exec(ffmpeg, segmentArgs(seg, output: out), range: range, expected: seg.length)
            guard r.status == 0 else { throw ProcessingError.failed(L("Remux failed: %@", r.stderr.trimmed)) }
            return
        }

        // Several kept parts: write each one, then join them without re-encoding
        let work = out.deletingLastPathComponent()
            .appendingPathComponent(".videocleaner-\(UUID().uuidString.prefix(8))", isDirectory: true)
        if !dryRun { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
        tempItems.append(work)
        let total = plan.outputDuration
        let joinShare = 0.08
        var done = 0.0
        var parts: [URL] = []
        for (i, seg) in plan.segments.enumerated() {
            let part = work.appendingPathComponent("part\(i + 1).\(outExt)")
            log(.info, L("Part %lld/%lld: %@–%@", i + 1, plan.segments.count, TimeFormat.string(seg.start), TimeFormat.string(seg.end)))
            let span = range.upperBound - range.lowerBound
            let lo = range.lowerBound + span * (1 - joinShare) * done / total
            let hi = range.lowerBound + span * (1 - joinShare) * (done + seg.length) / total
            let r = try await exec(ffmpeg, segmentArgs(seg, output: part), range: lo...hi, expected: seg.length)
            guard r.status == 0 else { throw ProcessingError.failed(L("Cutting part %lld failed: %@", i + 1, r.stderr.trimmed)) }
            parts.append(part)
            done += seg.length
        }

        let list = work.appendingPathComponent("parts.txt")
        let listText = parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n") + "\n"
        if !dryRun { try listText.write(to: list, atomically: true, encoding: .utf8) }
        log(.info, L("Joining %lld parts", parts.count))
        var join = Self.common + Self.progressArgs + ["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0", "-c", "copy"]
        // Make sure languages/titles survive the join
        for (pos, s) in audio.enumerated() {
            join += ["-metadata:s:a:\(pos)", "language=\(finalLanguage(s))"]
            if let t = s.title { join += ["-metadata:s:a:\(pos)", "title=\(t)"] }
        }
        for (pos, s) in subs.enumerated() {
            join += ["-metadata:s:s:\(pos)", "language=\(finalLanguage(s))"]
            if let t = s.title { join += ["-metadata:s:s:\(pos)", "title=\(t)"] }
        }
        if !audio.isEmpty { join += ["-disposition:a:0", "default"] }
        let joinedCodec = reencode ? (video.codec == "hevc" ? "hevc" : "h264") : video.codec
        if Self.mp4Family.contains(outExt) && joinedCodec == "hevc" { join += ["-tag:v", "hvc1"] }
        join += ["-strict", "-2", out.path]
        let span = range.upperBound - range.lowerBound
        let r = try await exec(ffmpeg, join, range: (range.upperBound - span * joinShare)...range.upperBound, expected: total)
        guard r.status == 0 else { throw ProcessingError.failed(L("Joining failed: %@", r.stderr.trimmed)) }
    }

    // MARK: - Helpers

    @discardableResult
    func exec(_ tool: URL, _ args: [String], range: ClosedRange<Double>? = nil, expected: Double? = nil,
              mkvProgress: Bool = false) async throws -> CommandResult {
        log(.command, ProcessRunner.shellLine(tool, args))
        if dryRun { return CommandResult(status: 0, stdout: "", stderr: "") }
        try Task.checkCancellation()
        let progress = progressHandler
        let lineHandler: (@Sendable (String) -> Void)?
        if let range {
            let span = range.upperBound - range.lowerBound
            if mkvProgress {
                lineHandler = { line in
                    guard line.hasPrefix("#GUI#progress ") else { return }
                    let pct = Double(line.dropFirst(14).replacingOccurrences(of: "%", with: "")) ?? 0
                    progress(range.lowerBound + span * min(1, pct / 100))
                }
            } else if let expected, expected > 0 {
                lineHandler = { line in
                    guard line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                          let us = Double(line.split(separator: "=").last ?? "") else { return }
                    progress(range.lowerBound + span * min(1, max(0, us / 1_000_000 / expected)))
                }
            } else {
                lineHandler = nil
            }
        } else {
            lineHandler = nil
        }
        return try await ProcessRunner.run(tool, args, onStdoutLine: lineHandler)
    }

    /// Is the file still being written (downloaded/copied)? Same heuristics as the script.
    func isFileGrowing() async -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: input.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) <= 30 else { return false }
        let size1 = attrs[.size] as? Int64 ?? 0
        try? await Task.sleep(for: .seconds(2))
        let size2 = (try? fm.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
        return size1 != size2
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
