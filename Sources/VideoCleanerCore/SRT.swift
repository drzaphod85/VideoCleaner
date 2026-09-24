// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct SubtitleCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum SRT {
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})"#)
    private static let fontOpen = try! NSRegularExpression(pattern: #"<font[^>]*>"#, options: .caseInsensitive)
    private static let fontClose = try! NSRegularExpression(pattern: #"</font>"#, options: .caseInsensitive)
    private static let alignment = try! NSRegularExpression(pattern: #"\{\\an\d\}"#)

    /// Decodes subtitle file data (UTF-8 with or without BOM, falling back to Windows-1252/Latin-1).
    public static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    public static func parse(_ text: String) -> [SubtitleCue] {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        var cues: [SubtitleCue] = []
        var current: SubtitleCue?
        var textLines: [String] = []

        func flush() {
            if var c = current {
                // Drop a trailing numeric line that actually belongs to the next block
                c.text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.text.isEmpty { cues.append(c) }
            }
            current = nil
            textLines = []
        }

        let lines = s.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let ns = line as NSString
            if let m = timeRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                // A counter line directly before the timing line is not text of the previous cue
                if let last = textLines.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                    textLines.removeLast()
                }
                flush()
                func v(_ g: Int) -> Double { Double(ns.substring(with: m.range(at: g))) ?? 0 }
                func ms(_ g: Int) -> Double {
                    let str = ns.substring(with: m.range(at: g))
                    return (Double(str) ?? 0) / pow(10, Double(str.count))
                }
                let start = v(1) * 3600 + v(2) * 60 + v(3) + ms(4)
                let end = v(5) * 3600 + v(6) * 60 + v(7) + ms(8)
                current = SubtitleCue(start: start, end: end, text: "")
            } else if current != nil {
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Blank line ends the cue unless the next line continues the text (tolerant parsing)
                    let next = i + 1 < lines.count ? lines[i + 1] : ""
                    if next.trimmingCharacters(in: .whitespaces).isEmpty || Int(next.trimmingCharacters(in: .whitespaces)) != nil {
                        flush()
                    } else {
                        textLines.append("")
                    }
                } else {
                    textLines.append(line)
                }
            }
        }
        flush()
        return cues
    }

    public static func timestamp(_ t: Double) -> String {
        let totalMs = Int((max(0, t) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let sec = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
    }

    public static func format(_ cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, c) in cues.enumerated() {
            out += "\(i + 1)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n\(c.text)\n\n"
        }
        return out
    }

    /// Removes <font …>, </font> and {\anN} tags (same cleanup as the original script).
    public static func cleanTags(_ text: String) -> String {
        var s = text
        for re in [fontOpen, fontClose, alignment] {
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: "")
        }
        return s
    }
}
