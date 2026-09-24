// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum ProbeError: LocalizedError {
    case missingTool(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let t): return L("%@ is missing — install with: brew install ffmpeg", t)
        case .failed(let m): return m
        }
    }
}

private struct FFProbeOutput: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codec_name: String?
        let codec_long_name: String?
        let codec_type: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let color_transfer: String?
        let sample_rate: String?
        let channels: Int?
        let channel_layout: String?
        let r_frame_rate: String?
        let avg_frame_rate: String?
        let bit_rate: String?
        let disposition: [String: Int]?
        let tags: [String: String]?
    }
    struct Format: Decodable {
        let format_name: String?
        let duration: String?
        let start_time: String?
        let size: String?
        let bit_rate: String?
    }
    let streams: [Stream]?
    let format: Format?
}

public enum Probe {
    public static func mediaInfo(_ url: URL, tools: ToolPaths) async throws -> MediaInfo {
        guard let ffprobe = tools.ffprobe else { throw ProbeError.missingTool("ffprobe") }
        let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-print_format", "json",
                                                      "-show_format", "-show_streams", url.path])
        guard r.status == 0 else {
            throw ProbeError.failed(L("ffprobe could not read the file: %@", r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return try parse(Data(r.stdout.utf8), url: url)
    }

    static func parse(_ data: Data, url: URL) throws -> MediaInfo {
        let out = try JSONDecoder().decode(FFProbeOutput.self, from: data)
        var counters: [StreamKind: Int] = [:]
        let streams: [StreamInfo] = (out.streams ?? []).map { s in
            let kind = StreamKind(rawValue: s.codec_type ?? "") ?? .other
            let ordinal = counters[kind, default: 0]
            counters[kind] = ordinal + 1
            func tag(_ key: String) -> String? {
                s.tags?.first(where: { $0.key.lowercased() == key })?.value
            }
            let disp = s.disposition ?? [:]
            return StreamInfo(
                index: s.index, kind: kind, ordinal: ordinal,
                codec: (s.codec_name ?? "unknown").lowercased(), codecLongName: s.codec_long_name,
                language: tag("language"), title: tag("title"),
                isDefault: disp["default"] == 1, isForced: disp["forced"] == 1,
                isHearingImpaired: disp["hearing_impaired"] == 1, isAttachedPicture: disp["attached_pic"] == 1,
                width: s.width, height: s.height, channels: s.channels, channelLayout: s.channel_layout,
                sampleRate: s.sample_rate.flatMap { Int($0) }, bitRate: s.bit_rate.flatMap { Int($0) },
                frameRate: rate(s.avg_frame_rate) ?? rate(s.r_frame_rate), pixelFormat: s.pix_fmt,
                profile: s.profile, colorTransfer: s.color_transfer)
        }
        let f = out.format
        return MediaInfo(url: url,
                         duration: f?.duration.flatMap { Double($0) } ?? 0,
                         startTime: f?.start_time.flatMap { Double($0) } ?? 0,
                         formatName: f?.format_name ?? "",
                         size: f?.size.flatMap { Int64($0) } ?? 0,
                         bitRate: f?.bit_rate.flatMap { Int($0) },
                         streams: streams)
    }

    private static func rate(_ s: String?) -> Double? {
        guard let s else { return nil }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0, parts[0] > 0 else { return nil }
        let r = parts[0] / parts[1]
        return r > 0 && r < 1000 ? r : nil
    }

    /// Keyframe times of the primary video stream, relative to the file start time (seconds, sorted).
    /// Reads packet headers only — no decoding.
    public static func keyframes(_ url: URL, info: MediaInfo, tools: ToolPaths) async throws -> [Double] {
        guard let ffprobe = tools.ffprobe else { throw ProbeError.missingTool("ffprobe") }
        guard let video = info.primaryVideo else { return [] }
        let r = try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "\(video.index)",
                                                      "-show_entries", "packet=pts_time,dts_time,flags",
                                                      "-of", "csv=p=0", url.path])
        guard r.status == 0 else { throw ProbeError.failed(L("Could not read keyframes")) }
        return parseKeyframes(r.stdout, startTime: info.startTime)
    }

    static func parseKeyframes(_ csv: String, startTime: Double) -> [Double] {
        var times: [Double] = []
        csv.enumerateLines { line, _ in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 2, f[f.count - 1].contains("K") else { return }
            if let t = Double(f[0]) ?? Double(f[1]) { times.append(max(0, t - startTime)) }
        }
        times.sort()
        var unique: [Double] = []
        for t in times where unique.last.map({ t - $0 > 0.0005 }) ?? true { unique.append(t) }
        return unique
    }
}
