import Foundation

/// A searchable string prepared once, so that search can find it however the query is typed
/// (#106): case, width and Latin accents are ignored, hiragana and katakana are the same, and
/// Japanese text can also be found by its reading in kana (きみ finds 君の名は) or in romaji
/// (kimi, kiminonawa, toukyou).
///
/// Readings come from the system's Japanese dictionary through `CFStringTokenizer`, the same one
/// behind the keyboard. They are a guess, one common reading per word (君 is きみ, not くん), so
/// some names will be read wrong. Making a key with a reading costs a dictionary lookup per word:
/// make keys off the main thread and keep them (see `AppModel.searchKey`).
public struct SearchKey: Sendable, Hashable {
    /// The text as `SearchKey.fold` leaves it.
    public let folded: String
    /// The reading in hiragana with spaces removed, as written (名は → なは) and, when different,
    /// with particles as spoken (なわ). Empty for text with no Japanese in it.
    public let readings: [String]
    /// The same readings in romaji, as `SearchKey.foldRomaji` leaves them.
    public let romaji: [String]

    /// A key with readings, for text that has Japanese in it. Slow: see above.
    public init(_ text: String) {
        folded = SearchKey.fold(text)
        guard SearchKey.hasJapanese(text) else {
            readings = []
            romaji = []
            return
        }
        let reading = SearchKey.reading(of: text)
        readings = Self.unique([reading.written, reading.spoken].filter { !$0.isEmpty })
        romaji = Self.unique([reading.writtenRomaji, reading.spokenRomaji].map(SearchKey.foldRomaji).filter { !$0.isEmpty })
    }

    /// A key without readings, which is fast. Used until the full key has been made.
    public init(plain text: String) {
        folded = SearchKey.fold(text)
        readings = []
        romaji = []
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Folding

    /// Lower case, full-width Latin and half-width katakana as usual (ＡＢＣ → abc, ｷﾐ → きみ),
    /// Latin accents removed (café → cafe), katakana as hiragana (キミ → きみ). Kana keep their
    /// voicing marks: が stays が.
    public static func fold(_ text: String) -> String {
        var text = text
        if text.unicodeScalars.contains(where: { (0xFF61...0xFF9F).contains($0.value) }) {
            // Half-width katakana to full width, with ﾞ and ﾟ joined to the kana before them.
            text = text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text
        }
        let wide = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in wide.decomposedStringWithCanonicalMapping.unicodeScalars {
            // Combining accents used by Latin, Greek and Cyrillic; not the kana voicing marks.
            if (0x0300...0x036F).contains(scalar.value) { continue }
            if (0x30A1...0x30F6).contains(scalar.value), let hiragana = Unicode.Scalar(scalar.value - 0x60) {
                scalars.append(hiragana)
            } else {
                scalars.append(scalar)
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }

    /// Hiragana as compared in readings: spaces and punctuation removed, and づ/ず, ぢ/じ, which
    /// sound the same, made one.
    static func foldReading(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in fold(text).unicodeScalars {
            switch scalar.value {
            case 0x3065: scalars.append("\u{305A}") // づ → ず
            case 0x3062: scalars.append("\u{3058}") // ぢ → じ
            default:
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.value == 0x30FC {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars)
    }

    /// Romaji as compared: lower case, letters and digits only (no spaces, apostrophes or
    /// hyphens), long vowels written once (tōkyō, toukyou and tookyoo are all tokyo), and the
    /// Kunrei spellings si, ti, tu, zi, di, du as Hepburn shi, chi, tsu, ji, ji, zu.
    public static func foldRomaji(_ text: String) -> String {
        var letters: [Character] = []
        for scalar in fold(text).unicodeScalars where scalar.isASCII {
            let c = Character(scalar)
            if c.isLetter || c.isNumber { letters.append(c) }
        }
        var spelled: [Character] = []
        var i = 0
        while i < letters.count {
            let c = letters[i]
            let next: Character? = i + 1 < letters.count ? letters[i + 1] : nil
            // Only when the s, t, z or d starts a syllable (not the h of "shi" or the s of "tsu").
            let previous = spelled.last
            let startsSyllable = previous == nil || "aiueon".contains(previous!) || previous == c
            if startsSyllable, let next {
                switch (c, next) {
                case ("s", "i"): spelled += ["s", "h", "i"]; i += 2; continue
                case ("t", "i"): spelled += ["c", "h", "i"]; i += 2; continue
                case ("t", "u"): spelled += ["t", "s", "u"]; i += 2; continue
                case ("z", "i"), ("d", "i"): spelled += ["j", "i"]; i += 2; continue
                case ("d", "u"): spelled += ["z", "u"]; i += 2; continue
                default: break
                }
            }
            spelled.append(c)
            i += 1
        }
        var result = ""
        for c in spelled {
            if let last = result.last, "aiueo".contains(c), c == last || (c == "u" && last == "o") {
                continue
            }
            result.append(c)
        }
        return result
    }

    // MARK: Readings

    /// Whether the text has kana or kanji in it.
    static func hasJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { isJapanese($0) }
    }

    static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3005, 0x3041...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F: true
        default: false
        }
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }

    struct Reading {
        var written = ""
        var spoken = ""
        var writtenRomaji = ""
        var spokenRomaji = ""
    }

    /// The text read word by word. Kana are read as written; words with kanji are read by the
    /// dictionary; anything else (Latin, digits) is kept as it is.
    static func reading(of text: String) -> Reading {
        var reading = Reading()
        for word in words(of: text) {
            let folded = fold(word.text)
            let kana: String
            var latin = word.latin.map { $0.lowercased() }
            if !folded.unicodeScalars.contains(where: { isJapanese($0) }) {
                // Latin letters and digits: the same in both.
                kana = folded
                latin = folded
            } else if folded.unicodeScalars.allSatisfy({ isKana($0) }) {
                kana = folded
                if latin == nil { latin = folded.applyingTransform(.latinToHiragana, reverse: true) }
            } else if let romaji = latin {
                kana = hiragana(fromRomaji: romaji) ?? folded
            } else {
                kana = folded
            }
            let romaji = latin ?? ""
            reading.written += kana
            reading.writtenRomaji += romaji
            // A particle on its own: は, を and へ are said わ, お and え.
            switch kana {
            case "は": reading.spoken += "わ"; reading.spokenRomaji += "wa"
            case "を": reading.spoken += "お"; reading.spokenRomaji += "o"
            case "へ": reading.spoken += "え"; reading.spokenRomaji += "e"
            default: reading.spoken += kana; reading.spokenRomaji += romaji
            }
        }
        reading.written = foldReading(reading.written)
        reading.spoken = foldReading(reading.spoken)
        return reading
    }

    /// Romaji with long-vowel marks (tōkyō) to hiragana (とうきょう).
    static func hiragana(fromRomaji romaji: String) -> String? {
        let long: [(String, String)] = [("ā", "aa"), ("ī", "ii"), ("ū", "uu"), ("ē", "ee"), ("ō", "ou"), ("â", "aa"), ("î", "ii"), ("û", "uu"), ("ê", "ee"), ("ô", "ou")]
        var plain = romaji
        for (mark, spelled) in long { plain = plain.replacingOccurrences(of: mark, with: spelled) }
        guard let kana = plain.applyingTransform(.latinToHiragana, reverse: false) else { return nil }
        // Letters the transform could not place mean the guess is unusable.
        return kana.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) ? nil : kana
    }

    /// The words of the text, with the dictionary's romaji for each where it has one.
    static func words(of text: String) -> [(text: String, latin: String?)] {
        let string = text as NSString
        let cfText = text as CFString
        let range = CFRange(location: 0, length: string.length)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, cfText, range, kCFStringTokenizerUnitWord, locale) else {
            return [(text, nil)]
        }
        var words: [(text: String, latin: String?)] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let token = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard token.location != kCFNotFound, token.length > 0 else { continue }
            let word = string.substring(with: NSRange(location: token.location, length: token.length))
            let attribute = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription)
            let latin = attribute.flatMap { $0 as? String }
            words.append((word, latin))
        }
        return words
    }
}

/// What the user typed in a search field, prepared once per search.
public struct SearchQuery: Sendable {
    /// The query as `SearchKey.fold` leaves it.
    public let folded: String
    /// For a query in kana or kanji: its reading in hiragana.
    let reading: String?
    /// For a query in Latin letters: the query as romaji.
    let romaji: String?

    public init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        folded = SearchKey.fold(text)
        if SearchKey.hasJapanese(text) {
            let reading = SearchKey.foldReading(SearchKey.reading(of: text).written)
            self.reading = reading.isEmpty ? nil : reading
            romaji = nil
        } else {
            reading = nil
            let latin = folded.unicodeScalars.contains { $0.properties.isAlphabetic }
            let romaji = latin ? SearchKey.foldRomaji(text) : ""
            self.romaji = romaji.isEmpty ? nil : romaji
        }
    }

    public var isEmpty: Bool { folded.isEmpty }

    public func matches(_ key: SearchKey) -> Bool {
        if key.folded.contains(folded) { return true }
        if let reading, key.readings.contains(where: { $0.contains(reading) }) { return true }
        if let romaji, key.romaji.contains(where: { $0.contains(romaji) }) { return true }
        return false
    }
}
