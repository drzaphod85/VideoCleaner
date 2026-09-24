// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Locations of the external tools. ffmpeg/ffprobe are required, mkvtoolnix is optional.
public struct ToolPaths: Sendable, Equatable {
    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var mkvmerge: URL?
    public var mkvextract: URL?
    public var mkvpropedit: URL?

    public init(ffmpeg: URL? = nil, ffprobe: URL? = nil, mkvmerge: URL? = nil, mkvextract: URL? = nil,
                mkvpropedit: URL? = nil) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.mkvmerge = mkvmerge
        self.mkvextract = mkvextract; self.mkvpropedit = mkvpropedit
    }

    public var hasFFmpeg: Bool { ffmpeg != nil && ffprobe != nil }
    public var hasMKVToolNix: Bool { mkvmerge != nil && mkvextract != nil && mkvpropedit != nil }

    /// Searches Homebrew, MacPorts, PATH and the MKVToolNix app bundle. `overrides` maps tool name → path.
    public static func locate(overrides: [String: String] = [:]) -> ToolPaths {
        let fm = FileManager.default
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for app in apps.sorted().reversed() where app.hasPrefix("MKVToolNix") && app.hasSuffix(".app") {
                dirs.append("/Applications/\(app)/Contents/MacOS")
            }
        }
        func find(_ name: String) -> URL? {
            if let o = overrides[name]?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
                return fm.isExecutableFile(atPath: o) ? URL(fileURLWithPath: o) : nil
            }
            for d in dirs {
                let p = (d as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
            return nil
        }
        return ToolPaths(ffmpeg: find("ffmpeg"), ffprobe: find("ffprobe"), mkvmerge: find("mkvmerge"),
                         mkvextract: find("mkvextract"), mkvpropedit: find("mkvpropedit"))
    }
}
