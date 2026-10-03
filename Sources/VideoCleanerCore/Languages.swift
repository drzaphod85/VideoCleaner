// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A language with its ISO 639-1 code, ISO 639-2/T code and alternative codes (639-2/B, BCP 47 variants).
public struct LanguageInfo: Sendable, Hashable, Identifiable {
    public let code2: String
    public let code3: String
    public let alternatives: [String]
    public let name: String
    public var id: String { code3 }
}

public enum Languages {
    /// Languages offered in pickers. The first block is shown at the top of menus.
    public static let all: [LanguageInfo] = [
        .init(code2: "sv", code3: "swe", alternatives: [], name: "Swedish"),
        .init(code2: "en", code3: "eng", alternatives: [], name: "English"),
        .init(code2: "da", code3: "dan", alternatives: [], name: "Danish"),
        .init(code2: "no", code3: "nor", alternatives: ["nb", "nn", "nob", "nno"], name: "Norwegian"),
        .init(code2: "fi", code3: "fin", alternatives: [], name: "Finnish"),
        .init(code2: "is", code3: "isl", alternatives: ["ice"], name: "Icelandic"),
        .init(code2: "de", code3: "deu", alternatives: ["ger"], name: "German"),
        .init(code2: "fr", code3: "fra", alternatives: ["fre"], name: "French"),
        .init(code2: "es", code3: "spa", alternatives: [], name: "Spanish"),
        .init(code2: "it", code3: "ita", alternatives: [], name: "Italian"),
        .init(code2: "pt", code3: "por", alternatives: [], name: "Portuguese"),
        .init(code2: "nl", code3: "nld", alternatives: ["dut"], name: "Dutch"),
        .init(code2: "ru", code3: "rus", alternatives: [], name: "Russian"),
        .init(code2: "pl", code3: "pol", alternatives: [], name: "Polish"),
        .init(code2: "ja", code3: "jpn", alternatives: [], name: "Japanese"),
        .init(code2: "zh", code3: "zho", alternatives: ["chi"], name: "Chinese"),
        .init(code2: "ko", code3: "kor", alternatives: [], name: "Korean"),
        .init(code2: "ar", code3: "ara", alternatives: [], name: "Arabic"),
        .init(code2: "tr", code3: "tur", alternatives: [], name: "Turkish"),
        .init(code2: "el", code3: "ell", alternatives: ["gre"], name: "Greek"),
        .init(code2: "he", code3: "heb", alternatives: ["iw"], name: "Hebrew"),
        .init(code2: "cs", code3: "ces", alternatives: ["cze"], name: "Czech"),
        .init(code2: "sk", code3: "slk", alternatives: ["slo"], name: "Slovak"),
        .init(code2: "hu", code3: "hun", alternatives: [], name: "Hungarian"),
        .init(code2: "ro", code3: "ron", alternatives: ["rum"], name: "Romanian"),
        .init(code2: "bg", code3: "bul", alternatives: [], name: "Bulgarian"),
        .init(code2: "uk", code3: "ukr", alternatives: [], name: "Ukrainian"),
        .init(code2: "hr", code3: "hrv", alternatives: [], name: "Croatian"),
        .init(code2: "sr", code3: "srp", alternatives: [], name: "Serbian"),
        .init(code2: "sl", code3: "slv", alternatives: [], name: "Slovenian"),
        .init(code2: "et", code3: "est", alternatives: [], name: "Estonian"),
        .init(code2: "lv", code3: "lav", alternatives: [], name: "Latvian"),
        .init(code2: "lt", code3: "lit", alternatives: [], name: "Lithuanian"),
        .init(code2: "ca", code3: "cat", alternatives: [], name: "Catalan"),
        .init(code2: "eu", code3: "eus", alternatives: ["baq"], name: "Basque"),
        .init(code2: "fa", code3: "fas", alternatives: ["per"], name: "Persian"),
        .init(code2: "hi", code3: "hin", alternatives: [], name: "Hindi"),
        .init(code2: "ta", code3: "tam", alternatives: [], name: "Tamil"),
        .init(code2: "te", code3: "tel", alternatives: [], name: "Telugu"),
        .init(code2: "th", code3: "tha", alternatives: [], name: "Thai"),
        .init(code2: "vi", code3: "vie", alternatives: [], name: "Vietnamese"),
        .init(code2: "id", code3: "ind", alternatives: [], name: "Indonesian"),
        .init(code2: "ms", code3: "msa", alternatives: ["may"], name: "Malay"),
    ]

    private static let lookup: [String: LanguageInfo] = {
        var map: [String: LanguageInfo] = [:]
        for lang in all {
            map[lang.code2] = lang
            map[lang.code3] = lang
            for alt in lang.alternatives { map[alt] = lang }
        }
        return map
    }()

    /// Lower-cases and strips a BCP 47 region suffix ("en-US" → "en").
    private static func clean(_ code: String?) -> String {
        guard var c = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !c.isEmpty else { return "" }
        if let dash = c.firstIndex(where: { $0 == "-" || $0 == "_" }) { c = String(c[..<dash]) }
        return c
    }

    public static func info(for code: String?) -> LanguageInfo? { lookup[clean(code)] }

    /// Is this a plausible language code (2–3 letters)?
    public static func isValidCode(_ code: String) -> Bool {
        let c = clean(code)
        return (2...3).contains(c.count) && c.allSatisfy { $0 >= "a" && $0 <= "z" }
    }

    /// Three-letter code used for container metadata and comparisons ("sv" → "swe", "ger" → "deu").
    /// Empty/unknown → "und".
    public static func normalized3(_ code: String?) -> String {
        let c = clean(code)
        if c.isEmpty { return "und" }
        if let info = lookup[c] { return info.code3 }
        return c
    }

    /// Code used in .srt file names — two letters when known ("swe" → "sv").
    public static func srtCode(_ code: String?) -> String {
        let c = clean(code)
        if c.isEmpty { return "und" }
        return lookup[c]?.code2 ?? c
    }

    /// Language name in the user's UI language (e.g. "svenska", "Swedish", "ruotsi").
    public static func displayName(_ code: String?) -> String {
        let c = clean(code)
        if c.isEmpty || c == "und" { return L("Unknown language") }
        let lookupCode = lookup[c]?.code2 ?? c
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
        if let name = locale.localizedString(forLanguageCode: lookupCode) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return lookup[c]?.name ?? c.uppercased()
    }

    // MARK: Favorites

    static let nordicRegions: Set<String> = ["SE", "NO", "DK", "FI", "IS", "AX", "FO", "GL", "SJ"]

    /// Languages shown first in language menus, suggested from the app's language and the user's region:
    /// in the Nordic countries the Nordic languages plus English and German; elsewhere the region's own
    /// language plus the big European ones. The app's language always comes first.
    public static func defaultFavorites(appLanguage: String, region: String?) -> [String] {
        var list: [String]
        let r = region?.uppercased()
        if let r, nordicRegions.contains(r) {
            list = ["swe", "nor", "dan", "fin", "isl", "eng", "deu"]
        } else {
            list = ["eng"]
            if let r, let lang = Locale.Language(identifier: "und-\(r)").maximalIdentifier.split(separator: "-").first {
                list.append(normalized3(String(lang)))
            }
            list += ["fra", "deu", "spa", "ita"]
        }
        list.insert(normalized3(appLanguage), at: 0)
        var seen = Set<String>()
        return list.filter { $0 != "und" && seen.insert($0).inserted }
    }

    // MARK: Guessing from file names

    /// Short words that are also language codes but far more often mean something else in file names.
    private static let ambiguousCodes: Set<String> = [
        "is", "it", "no", "to", "in", "on", "at", "be", "me", "we", "he", "so", "do", "my", "an", "or", "as",
        "us", "id", "ca", "hi", "ta", "te", "et", "ms", "the", "and", "for", "tv", "hd", "uk",
    ]

    private static let nameLookup: [String: String] = {
        var map: [String: String] = [:]
        let locales = ["en", "sv", "da", "nb", "fi", "is", "de", "fr", "es", "it", "nl"]
        for lang in all {
            map[lang.name.lowercased()] = lang.code3
            for l in locales {
                if let n = Locale(identifier: l).localizedString(forLanguageCode: lang.code2) {
                    map[n.lowercased()] = lang.code3
                }
            }
            if let native = Locale(identifier: lang.code2).localizedString(forLanguageCode: lang.code2) {
                map[native.lowercased()] = lang.code3
            }
        }
        // Common extras seen in release and recording names
        map["swedish"] = "swe"; map["svensk"] = "swe"; map["svenskt"] = "swe"; map["svtal"] = "swe"
        map["dansk"] = "dan"; map["norsk"] = "nor"; map["suomi"] = "fin"; map["deutsch"] = "deu"
        return map
    }()

    /// Guesses the language from a file name such as "Film.svenska.TV.ac3" or "Movie.2019.SWE.dts".
    public static func guess(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let tokens = stem.split(whereSeparator: { !$0.isLetter }).map { String($0) }
        for t in tokens.reversed() {
            if let code = nameLookup[t.lowercased()] { return code }
        }
        for t in tokens.reversed() {
            let lower = t.lowercased()
            guard (2...3).contains(lower.count), !ambiguousCodes.contains(lower), let info = lookup[lower] else { continue }
            return info.code3
        }
        return nil
    }

    /// Parses a user-entered list like "sv, en" or "swe eng;de" into normalized three-letter codes.
    public static func parseList(_ text: String) -> Set<String> {
        let tokens = text.lowercased().split(whereSeparator: { ", ;\n\t".contains($0) })
        return Set(tokens.map(String.init).filter(isValidCode).map { normalized3($0) })
    }
}
