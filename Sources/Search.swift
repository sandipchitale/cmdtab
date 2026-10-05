import AppKit
import Carbon.HIToolbox

/// A search (F) that's up: keys type into it, or (read-only, after Esc) they're the usual commands again, with what it
/// found kept.
enum SearchState {
    case typing, readOnly
}

/// Type to search (F): every word typed must appear in a tile's name or title, ignoring case and accents.
enum Search {
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// How well `fields` (a name, a title) match `query`, lower being better, or nil if some word of it is in none
    /// of them. The first word decides: 0 when a field starts with it, 1 when a later word in a field does, 2 when
    /// it's only inside a word. An empty query matches everything.
    static func rank(_ query: String, in fields: [String]) -> Int? {
        var result = 0
        for (i, word) in query.split(whereSeparator: \.isWhitespace).enumerated() {
            guard let best = fields.compactMap({ rank(String(word), in: $0) }).min() else { return nil }
            if i == 0 { result = best }
        }
        return result
    }

    /// 0: `field` starts with `word`; 1: a later word in it does; 2: it's only inside a word; nil: it isn't there.
    private static func rank(_ word: String, in field: String) -> Int? {
        var found: Int?
        var from = field.startIndex
        while let match = field.range(of: word, options: options, range: from..<field.endIndex, locale: .current) {
            if match.lowerBound == field.startIndex { return 0 }
            let before = field[field.index(before: match.lowerBound)]
            if !before.isLetter && !before.isNumber { return 1 }
            found = 2
            from = field.index(after: match.lowerBound)
        }
        return found
    }
}

/// The text a key types in the current keyboard layout, with only Shift and Caps Lock applied, so typing while still
/// holding ⌘ (Cmd+Tab) or ⌥ (Option+Tab) gives plain letters. Input methods that compose text (Japanese, Chinese,
/// Korean) don't apply: this is the keyboard layout under them.
enum KeyText {
    /// Nil for keys that type nothing printable (Tab, Return, Esc, Delete, the arrows, function keys).
    @MainActor
    static func text(keycode: Int64, flags: CGEventFlags) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        // Carbon modifier bits, shifted down by 8 as UCKeyTranslate wants them.
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey >> 8) }
        if flags.contains(.maskAlphaShift) { modifiers |= UInt32(alphaLock >> 8) }
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let keyboard = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            // No dead keys: a key that starts an accent types the accent itself, rather than waiting for the next key.
            return UCKeyTranslate(keyboard, UInt16(keycode), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        // Control characters, and the private-use ones AppKit gives the arrows and function keys.
        let printable = text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
        return printable ? text : nil
    }
}
