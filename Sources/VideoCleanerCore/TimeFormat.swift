// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum TimeFormat {
    /// "1:02:03.456" (hours only when needed, or always with `alwaysHours`).
    public static func string(_ t: Double, millis: Bool = true, alwaysHours: Bool = false) -> String {
        let totalMs = Int((max(0, t) * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        var out = (h > 0 || alwaysHours) ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        if millis { out += String(format: ".%03d", ms) }
        return out
    }

    /// Parses "[HH:]MM:SS[,.mmm]" or plain seconds ("00:55,855", "52:10.5", "95.2").
    public static func parse(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            guard let v = Double(p), v >= 0 else { return nil }
            if i < parts.count - 1 && p.contains(".") { return nil }
            total = total * 60 + v
        }
        return total
    }

    public static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
