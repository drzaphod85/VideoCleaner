// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum FileScanner {
    /// Containers that are kept as they are (or converted to MKV when asked).
    public static let modernExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov"]
    /// Older containers: always converted to MKV (losslessly — the streams are copied).
    public static let legacyExtensions: Set<String> = [
        "avi", "divx", "xvid", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "vob", "ts", "m2ts", "mts",
        "webm", "ogm", "ogv", "3gp", "3g2", "rm", "rmvb", "dv",
    ]
    public static let videoExtensions = modernExtensions.union(legacyExtensions)

    public static func isLegacy(_ url: URL) -> Bool { legacyExtensions.contains(url.pathExtension.lowercased()) }

    public static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix(".")
    }

    /// Expands files and folders (recursively) into a sorted, de-duplicated list of video files.
    public static func videoFiles(in urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted { result.append(URL(fileURLWithPath: path)) }
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                var found: [URL] = []
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in e where isVideo(f) {
                        if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            found.append(f)
                        }
                    }
                }
                found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
            } else if isVideo(url) {
                add(url)
            }
        }
        return result
    }
}
