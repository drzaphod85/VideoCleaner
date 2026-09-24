// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum StreamKind: String, Sendable {
    case video, audio, subtitle, attachment, data, other
}

public enum SubtitleCodecs {
    static let image: Set<String> = [
        "dvd_subtitle", "dvdsub", "hdmv_pgs_subtitle", "pgssub", "xsub", "vobsub", "dvb_subtitle", "dvb_teletext",
    ]
    /// Text-based subtitle codec? Unknown codecs are treated as text (same as the original script).
    public static func isText(_ codec: String) -> Bool { !image.contains(codec.lowercased()) }
}

public struct StreamInfo: Sendable, Identifiable, Hashable {
    public var id: Int { index }
    /// Absolute stream index (ffprobe index; also the mkvmerge track id for Matroska files).
    public let index: Int
    public let kind: StreamKind
    /// 0-based position among streams of the same kind (ffmpeg `a:N`, mkvpropedit `aN+1`).
    public let ordinal: Int
    public let codec: String
    public let codecLongName: String?
    public let language: String?
    public let title: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let isHearingImpaired: Bool
    public let isAttachedPicture: Bool
    public let width: Int?
    public let height: Int?
    public let channels: Int?
    public let channelLayout: String?
    public let sampleRate: Int?
    public let bitRate: Int?
    public let frameRate: Double?
    public let pixelFormat: String?
    public let profile: String?
    public let colorTransfer: String?

    public init(index: Int, kind: StreamKind, ordinal: Int, codec: String, codecLongName: String? = nil,
                language: String? = nil, title: String? = nil, isDefault: Bool = false, isForced: Bool = false,
                isHearingImpaired: Bool = false, isAttachedPicture: Bool = false, width: Int? = nil,
                height: Int? = nil, channels: Int? = nil, channelLayout: String? = nil, sampleRate: Int? = nil,
                bitRate: Int? = nil, frameRate: Double? = nil, pixelFormat: String? = nil, profile: String? = nil,
                colorTransfer: String? = nil) {
        self.index = index; self.kind = kind; self.ordinal = ordinal; self.codec = codec
        self.codecLongName = codecLongName; self.language = language; self.title = title
        self.isDefault = isDefault; self.isForced = isForced; self.isHearingImpaired = isHearingImpaired
        self.isAttachedPicture = isAttachedPicture; self.width = width; self.height = height
        self.channels = channels; self.channelLayout = channelLayout; self.sampleRate = sampleRate
        self.bitRate = bitRate; self.frameRate = frameRate; self.pixelFormat = pixelFormat
        self.profile = profile; self.colorTransfer = colorTransfer
    }

    public var isTextSubtitle: Bool { kind == .subtitle && SubtitleCodecs.isText(codec) }
    public var normalizedLanguage: String { Languages.normalized3(language) }
    public var hasLanguage: Bool { normalizedLanguage != "und" }
    public var is10Bit: Bool { (pixelFormat ?? "").contains("10") || (pixelFormat ?? "").contains("12") }
    public var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") }

    /// Short human description, e.g. "EAC3 · 5.1" or "HEVC · 1920×1080 · 23.976 fps".
    public var summary: String {
        var parts = [codec.uppercased()]
        switch kind {
        case .video:
            if let w = width, let h = height { parts.append("\(w)×\(h)") }
            if let f = frameRate { parts.append(String(format: "%.3g fps", f)) }
            if isHDR { parts.append("HDR") } else if is10Bit { parts.append("10-bit") }
        case .audio:
            if let layout = channelLayout, !layout.isEmpty {
                parts.append(layout.replacingOccurrences(of: "(side)", with: ""))
            } else if let ch = channels { parts.append(L("%lld ch", ch)) }
        case .subtitle:
            parts.append(isTextSubtitle ? L("text") : L("image"))
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

public struct MediaInfo: Sendable {
    public let url: URL
    public let duration: Double
    public let startTime: Double
    public let formatName: String
    public let size: Int64
    public let bitRate: Int?
    public let streams: [StreamInfo]

    public init(url: URL, duration: Double, startTime: Double, formatName: String, size: Int64, bitRate: Int?,
                streams: [StreamInfo]) {
        self.url = url; self.duration = duration; self.startTime = startTime; self.formatName = formatName
        self.size = size; self.bitRate = bitRate; self.streams = streams
    }

    public var videoStreams: [StreamInfo] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    public var audioStreams: [StreamInfo] { streams.filter { $0.kind == .audio } }
    public var subtitleStreams: [StreamInfo] { streams.filter { $0.kind == .subtitle } }
    public var primaryVideo: StreamInfo? { videoStreams.first }
    public var frameDuration: Double {
        guard let f = primaryVideo?.frameRate, f > 1 else { return 1.0 / 25.0 }
        return 1.0 / f
    }
}
