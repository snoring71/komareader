import Foundation

/// The patterns `FileNameReader` tries on a file name, in the user's order, each of which can be
/// turned off (Settings › File Names, #77). Kept on the device.
public struct FileNameRules: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable, Identifiable {
        /// `[作者] タイトル`, `(一般コミック) [作者] タイトル v01`: the author in leading brackets.
        case leadingAuthor
        /// `第07巻`, `07巻`, `第3話`, and `全5巻` for the number of volumes.
        case japaneseVolume
        /// `v03`, `Vol. 3`, `Volume 3`, `#12`, `Book 2`, `Issue 4`, `Ch. 12`, `Part 2`.
        case westernVolume
        /// A number at the end: `Starfall 3`, `Saga - 001`.
        case trailingNumber
        /// `Title v03 (2019) (Publisher)`: a year in brackets, and the bracket after it.
        case yearPublisher
        /// The folder's name for the series (and author) when the file name has none, as in
        /// `ARIA/第07巻.cbz`.
        case folderName

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .leadingAuthor: return "Author in Leading Brackets"
            case .japaneseVolume: return "Japanese Volume (第07巻)"
            case .westernVolume: return "Volume (v03, Vol. 3, #12)"
            case .trailingNumber: return "Number at the End"
            case .yearPublisher: return "Year and Publisher in Brackets"
            case .folderName: return "Series from the Folder Name"
            }
        }

        public var example: String {
            switch self {
            case .leadingAuthor: return "[天野こずえ] ARIA 第07巻"
            case .japaneseVolume: return "ARIA 第07巻, 全12巻"
            case .westernVolume: return "Berserk v02, Batman #12"
            case .trailingNumber: return "Starfall 3, Saga - 001"
            case .yearPublisher: return "Saga v03 (2019) (Image)"
            case .folderName: return "ARIA/第07巻"
            }
        }
    }

    public struct Rule: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var isOn: Bool
        public var id: Kind { kind }
        public init(_ kind: Kind, isOn: Bool = true) {
            self.kind = kind
            self.isOn = isOn
        }
    }

    public var rules: [Rule]

    public init(rules: [Rule]) {
        // Every kind exactly once, so rules added in a later version show up switched on.
        var seen: Set<Kind> = []
        var all = rules.filter { seen.insert($0.kind).inserted }
        for kind in Kind.allCases where !seen.contains(kind) { all.append(Rule(kind)) }
        self.rules = all
    }

    public static let standard = FileNameRules(rules: Kind.allCases.map { Rule($0) })

    public func isOn(_ kind: Kind) -> Bool { rules.first { $0.kind == kind }?.isOn ?? false }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rules: try container.decode([Rule].self, forKey: .rules))
    }
}

/// Works out what it can from a book's file name, for the many books with no ComicInfo.xml
/// (#77): "ARIA 第02巻" is ARIA volume 2, "[天野こずえ] ARIA 第02巻" adds the author,
/// "Saga 001 (2012) (Digital)" is Saga number 1 from 2012.
public enum FileNameReader {
    public static func read(_ title: String, folder: String = "", rules: FileNameRules = .standard) -> BookData {
        var info = BookData()
        var name = halfwidthASCII(title)

        if rules.isOn(.leadingAuthor), let found = leadingAuthor(name) {
            info.writers = found.authors
            name = found.rest
        }
        if rules.isOn(.yearPublisher) {
            let (year, publisher) = yearAndPublisher(name)
            info.year = year
            info.publisher = publisher
        }
        // Drop bracketed notes: [Group], (2012), (Digital), 【完】.
        name = replace(Self.brackets, in: name, with: " ")
        name = name.replacingOccurrences(of: "_", with: " ")
        name = replace(Self.spaces, in: name, with: " ").trimmingCharacters(in: .whitespaces)

        if rules.isOn(.japaneseVolume), let match = Self.complete.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let whole = Range(match.range, in: name), let digits = Range(match.range(at: 1), in: name) {
            info.count = Int(name[digits])
            name.removeSubrange(whole)
            name = name.trimmingCharacters(in: .whitespaces)
        }

        var matched = false
        for rule in rules.rules where rule.isOn {
            let patterns: [NSRegularExpression]
            switch rule.kind {
            case .japaneseVolume: patterns = [Self.japanese]
            case .westernVolume: patterns = [Self.western]
            case .trailingNumber: patterns = [Self.trailing]
            default: continue
            }
            for regex in patterns {
                guard let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                      let whole = Range(match.range, in: name),
                      let digits = Range(match.range(at: 1), in: name) else { continue }
                let series = clean(String(name[..<whole.lowerBound]))
                let number = BookData.trimNumber(String(name[digits]))
                if series.isEmpty {
                    // A lone four-digit number is more likely a title such as "1984" than a volume.
                    if rule.kind == .trailingNumber, (Int(number) ?? 0) >= 1000 { continue }
                    // Only a volume marker ("第07巻"): the folder may name the series.
                    guard rules.isOn(.folderName), let fromFolder = folderSeries(folder, rules: rules, into: &info) else { continue }
                    info.series = fromFolder
                } else {
                    info.series = series
                }
                info.number = number
                matched = true
                break
            }
            if matched { break }
        }
        if !matched {
            let cleaned = clean(name)
            if cleaned.isEmpty, rules.isOn(.folderName), let fromFolder = folderSeries(folder, rules: rules, into: &info) {
                info.series = fromFolder
            } else {
                info.series = cleaned.isEmpty ? title : cleaned
            }
        }
        // The folder can also give the author when the file name does not.
        if info.writers == nil, rules.isOn(.folderName), rules.isOn(.leadingAuthor), !folder.isEmpty,
           let found = leadingAuthor(halfwidthASCII((folder as NSString).lastPathComponent)) {
            info.writers = found.authors
        }
        return info
    }

    /// The series named by the folder's last part, cleaned the same way.
    private static func folderSeries(_ folder: String, rules: FileNameRules, into info: inout BookData) -> String? {
        let last = (folder as NSString).lastPathComponent
        guard !last.isEmpty else { return nil }
        var name = halfwidthASCII(last)
        if rules.isOn(.leadingAuthor), let found = leadingAuthor(name) {
            if info.writers == nil { info.writers = found.authors }
            name = found.rest
        }
        name = replace(Self.brackets, in: name, with: " ")
        name = clean(replace(Self.spaces, in: name.replacingOccurrences(of: "_", with: " "), with: " "))
        return name.isEmpty ? nil : name
    }

    /// `[作者] タイトル` after any leading `(一般コミック)`: the authors and the rest of the name.
    static func leadingAuthor(_ name: String) -> (authors: [String], rest: String)? {
        guard let match = Self.leading.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let whole = Range(match.range, in: name), let inside = Range(match.range(at: 1), in: name) else { return nil }
        let rest = String(name[whole.upperBound...]).trimmingCharacters(in: .whitespaces)
        // A name that is all brackets ("[Group] [Title]") keeps its brackets.
        guard !rest.isEmpty, !rest.hasPrefix("[") else { return nil }
        let authors = name[inside].split(whereSeparator: { "×✕&＆/／".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !authors.isEmpty else { return nil }
        return (authors, rest)
    }

    /// A year in brackets, `(2019)`, and the bracket right after it as the publisher, unless it
    /// is a scan or release note such as `(Digital)`.
    static func yearAndPublisher(_ name: String) -> (Int?, String?) {
        guard let match = Self.year.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let digits = Range(match.range(at: 1), in: name), let year = Int(name[digits]) else { return (nil, nil) }
        var publisher: String?
        if let next = Range(match.range(at: 2), in: name) {
            let text = name[next].trimmingCharacters(in: .whitespaces)
            let lowered = text.lowercased()
            let isNote = Self.releaseNotes.contains { lowered == $0 || lowered.hasPrefix($0 + " ") || lowered.hasPrefix($0 + "-") }
                || lowered.contains("scan") || lowered.contains("rip") || text.rangeOfCharacter(from: .decimalDigits) != nil
            if !isNote, !text.isEmpty { publisher = text }
        }
        return (year, publisher)
    }

    private static let releaseNotes = [
        "digital", "digital-empire", "c2c", "f", "fixed", "hq", "hd", "lq", "color", "colour", "colored",
        "raw", "raws", "complete", "web", "webrip", "repack", "batch", "omnibus", "english", "eng", "jp", "jpn",
        "japanese", "chinese", "完", "完結", "re", "v2", "dc", "marvel-scans",
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed, so a failure here is a programming mistake.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let number = #"(\d+(?:\.\d+)?)"#
    nonisolated(unsafe) private static let leading = regex(#"^\s*(?:\([^)]*\)\s*)*\[([^\]]+)\]"#)
    nonisolated(unsafe) private static let year = regex(#"\(((?:19|20)\d{2})\)(?:\s*\(([^)]*)\))?"#)
    nonisolated(unsafe) private static let brackets = regex(#"\[[^\]]*\]|\([^)]*\)|【[^】]*】|\{[^}]*\}"#)
    nonisolated(unsafe) private static let spaces = regex(#"\s+"#)
    nonisolated(unsafe) private static let complete = regex(#"全\s*(\d+)\s*巻"#)
    nonisolated(unsafe) private static let japanese = regex(#"第?\s*"# + number + #"\s*[巻話集]"#)
    nonisolated(unsafe) private static let western = regex(#"(?i)(?:\bvol(?:ume)?\.?|\bv(?=\d)|\bbook|\bissue|\bno\.|#|\bch(?:apter)?\.?|\bpart)\s*"# + number)
    nonisolated(unsafe) private static let trailing = regex(#"(?:^|[\s\-.,])"# + number + #"\s*$"#)

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Full-width letters, digits and punctuation (Ａ, ０, ＃) as plain ASCII. Kana is left alone.
    static func halfwidthASCII(_ text: String) -> String {
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
}

/// A book's series and number from its file name alone (the file name part of `FileNameReader`).
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
        let info = FileNameReader.read(title)
        return Parsed(series: info.series ?? title, number: info.number)
    }
}
