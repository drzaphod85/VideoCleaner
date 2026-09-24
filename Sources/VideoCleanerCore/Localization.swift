// VideoCleaner — Copyright (C) 2026 Lasse L
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Looks up an English source string in the app's Localizable.strings and formats it.
/// Translations live in Resources/<lang>.lproj/Localizable.strings (da, fi, is, nb, sv).
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}
