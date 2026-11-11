import Foundation

/// Works out a book's series and number from its file name, for books that have no metadata
/// yet: "ARIA 第02巻" is ARIA volume 2, "Saga 001 (2012) (Digital)" is Saga number 1.
public enum SeriesName {
    public struct Parsed: Equatable, Sendable {
        public var series: String
        public var number: String?
        public init(series: String, number: String?) {
            self.series = series
            self.number = number
        }
    }

    public static func parse(_ title: String) -> Parsed {
        var name = halfwidthASCII(title)
        // Drop bracketed notes: [Group], (2012), (Digital), 【完】.
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"【[^】]*】"#, #"\{[^}]*\}"#] {
            name = name.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        name = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let number = #"(\d+(?:\.\d+)?)"#
        let patterns = [
            // Japanese volume and chapter markers: 第02巻, 02巻, 第3話.
            #"第?\s*"# + number + #"\s*[巻話集]"#,
            // Vol. 3, Volume 3, v03, Book 2, Issue 4, #5, Ch. 12, Part 2.
            #"(?i)(?:\bvol(?:ume)?\.?|\bv(?=\d)|\bbook|\bissue|\bno\.|#|\bch(?:apter)?\.?|\bpart)\s*"# + number,
            // A number at the end: Starfall 3, Saga - 001.
            #"(?:^|[\s\-.,])"# + number + #"\s*$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let whole = Range(match.range, in: name),
                  let digits = Range(match.range(at: 1), in: name) else { continue }
            let series = clean(String(name[..<whole.lowerBound]))
            guard !series.isEmpty else { continue }
            return Parsed(series: series, number: trimZeros(String(name[digits])))
        }
        return Parsed(series: clean(name).isEmpty ? title : clean(name), number: nil)
    }

    /// Full-width letters, digits and punctuation (Ａ, ０, ＃) as plain ASCII. Kana is left alone.
    private static func halfwidthASCII(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0xFF01...0xFF5E: return Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
            case 0x3000: return " "
            default: return scalar
            }
        }))
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.,:#").union(.whitespaces))
    }

    /// "001" gives "1", "02.5" gives "2.5", "0" stays "0".
    private static func trimZeros(_ number: String) -> String {
        var result = Substring(number)
        while result.count > 1, result.first == "0", result.dropFirst().first != "." { result = result.dropFirst() }
        return String(result)
    }
}
