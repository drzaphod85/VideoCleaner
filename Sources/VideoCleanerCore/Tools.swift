// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Locations of the external tools. ffmpeg/ffprobe are required (a copy is bundled with the app),
/// mkvtoolnix is optional.
public struct ToolPaths: Sendable, Equatable {
    public enum Source: String, Sendable {
        case bundled    // inside VideoCleaner.app
        case installed  // Homebrew, MacPorts or PATH
        case custom     // chosen in Settings
    }

    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var mkvmerge: URL?
    public var mkvextract: URL?
    public var mkvpropedit: URL?
    /// Where the ffmpeg in use comes from, and its version ("9.0.2").
    public var ffmpegSource: Source?
    public var ffmpegVersion: String?
    /// Version of the ffmpeg bundled with the app, also when a newer installed one is used.
    public var bundledFFmpegVersion: String?

    public init(ffmpeg: URL? = nil, ffprobe: URL? = nil, mkvmerge: URL? = nil, mkvextract: URL? = nil,
                mkvpropedit: URL? = nil) {
        self.ffmpeg = ffmpeg; self.ffprobe = ffprobe; self.mkvmerge = mkvmerge
        self.mkvextract = mkvextract; self.mkvpropedit = mkvpropedit
    }

    public var hasFFmpeg: Bool { ffmpeg != nil && ffprobe != nil }
    public var hasMKVToolNix: Bool { mkvmerge != nil && mkvextract != nil && mkvpropedit != nil }

    /// Finds the tools. ffmpeg: a path chosen in Settings wins; otherwise the bundled copy is used unless an
    /// installed one (Homebrew, MacPorts, PATH) is newer. ffprobe always comes from the same place as ffmpeg.
    /// `overrides` maps tool name → path; `bundledDirectory` is the app's Contents/Helpers.
    public static func locate(overrides: [String: String] = [:], bundledDirectory: URL? = nil) -> ToolPaths {
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
        func override(_ name: String) -> URL?? {
            guard let o = overrides[name]?.trimmingCharacters(in: .whitespaces), !o.isEmpty else { return nil }
            return .some(fm.isExecutableFile(atPath: o) ? URL(fileURLWithPath: o) : nil)
        }
        func installed(_ name: String) -> URL? {
            for d in dirs {
                let p = (d as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
            return nil
        }
        func find(_ name: String) -> URL? { override(name) ?? installed(name) }

        var tools = ToolPaths(mkvmerge: find("mkvmerge"), mkvextract: find("mkvextract"), mkvpropedit: find("mkvpropedit"))

        let bundled = bundledDirectory.map { $0.appendingPathComponent("ffmpeg") }.flatMap { fm.isExecutableFile(atPath: $0.path) ? $0 : nil }
        let bundledVersion = bundled.flatMap(version(of:))
        tools.bundledFFmpegVersion = bundledVersion

        if let custom = override("ffmpeg") {
            tools.ffmpeg = custom
            tools.ffprobe = override("ffprobe") ?? custom.map { $0.deletingLastPathComponent().appendingPathComponent("ffprobe") }
            tools.ffmpegSource = .custom
            tools.ffmpegVersion = custom.flatMap(version(of:))
        } else {
            let external = installed("ffmpeg")
            let externalVersion = external.flatMap(version(of:))
            let useExternal: Bool
            switch (bundled, external) {
            case (nil, _): useExternal = external != nil
            case (_, nil): useExternal = false
            default: useExternal = isNewer(externalVersion, than: bundledVersion)
            }
            if useExternal, let external {
                tools.ffmpeg = external
                tools.ffprobe = sibling("ffprobe", of: external) ?? installed("ffprobe")
                tools.ffmpegSource = .installed
                tools.ffmpegVersion = externalVersion
            } else if let bundled {
                tools.ffmpeg = bundled
                tools.ffprobe = sibling("ffprobe", of: bundled)
                tools.ffmpegSource = .bundled
                tools.ffmpegVersion = bundledVersion
            }
        }
        if let probe = override("ffprobe") { tools.ffprobe = probe }
        return tools
    }

    private static func sibling(_ name: String, of tool: URL) -> URL? {
        let url = tool.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// "9.0.2" from `ffmpeg -version` ("ffmpeg version 9.0.2 Copyright …"). Development builds give their own
    /// tag (e.g. "N-123456-g…").
    public static func version(of ffmpeg: URL) -> String? {
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-hide_banner", "-version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseVersion(String(decoding: data, as: UTF8.self))
    }

    static func parseVersion(_ output: String) -> String? {
        guard let line = output.split(separator: "\n").first,
              let range = line.range(of: "version ") else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.split(separator: " ").first.map(String.init)
        // Homebrew and distributions may add suffixes ("9.0.2-tessus", "9.0.2_1")
        return token
    }

    /// Compares release numbers ("9.1" > "9.0.2"). An unparsable (development) version is never "newer",
    /// so the known bundled build is kept.
    static func isNewer(_ a: String?, than b: String?) -> Bool {
        guard let a = numbers(a) else { return false }
        guard let b = numbers(b) else { return true }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func numbers(_ v: String?) -> [Int]? {
        guard let v else { return nil }
        let head = v.prefix { $0.isNumber || $0 == "." }
        let parts = head.split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }
}
