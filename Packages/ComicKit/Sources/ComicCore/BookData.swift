import Foundation

/// What is known about a book: its title, series, creators, publisher and so on (#75, #76, #77).
/// The same shape holds each of the three places a value can come from: the user's own edits
/// (the synced record's `metadata`), the file's ComicInfo.xml, and its file name. Every field is
/// optional; `overlaid(on:)` stacks them so the first place that has a value wins.
public struct BookData: Codable, Equatable, Hashable, Sendable {
    public var title: String?
    public var series: String?
    public var number: String?
    public var volume: String?
    /// How many books the series has (ComicInfo `Count`, or `全5巻` in a file name).
    public var count: Int?
    public var summary: String?
    public var year: Int?
    public var month: Int?
    public var day: Int?
    public var writers: [String]?
    public var pencillers: [String]?
    public var inkers: [String]?
    public var colorists: [String]?
    public var letterers: [String]?
    public var coverArtists: [String]?
    public var editors: [String]?
    public var translators: [String]?
    public var publisher: String?
    public var imprint: String?
    public var genres: [String]?
    /// The file's own tags (ComicInfo `Tags`). The user's tags are kept apart, in `BookRecord.tags`.
    public var tags: [String]?
    public var language: String?
    public var ageRating: String?
    public var isbn: String?
    public var web: String?
    /// The file says it is manga read right to left (ComicInfo `Manga` = `YesAndRightToLeft`).
    public var rightToLeft: Bool?

    public init() {}

    public var isEmpty: Bool { self == BookData() }

    /// The creator roles, in the order Book Info lists them.
    public enum Role: String, CaseIterable, Codable, Sendable, Identifiable {
        case writer, penciller, inker, colorist, letterer, coverArtist, editor, translator
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .writer: return "Writer"
            case .penciller: return "Penciller"
            case .inker: return "Inker"
            case .colorist: return "Colorist"
            case .letterer: return "Letterer"
            case .coverArtist: return "Cover Artist"
            case .editor: return "Editor"
            case .translator: return "Translator"
            }
        }

        public var keyPath: WritableKeyPath<BookData, [String]?> {
            switch self {
            case .writer: return \.writers
            case .penciller: return \.pencillers
            case .inker: return \.inkers
            case .colorist: return \.colorists
            case .letterer: return \.letterers
            case .coverArtist: return \.coverArtists
            case .editor: return \.editors
            case .translator: return \.translators
            }
        }
    }

    /// The people the library files a book under as its authors: the writers, else the
    /// pencillers (a manga's mangaka is often only credited as the artist).
    public var authors: [String] {
        if let writers, !writers.isEmpty { return writers }
        return pencillers ?? []
    }

    /// Every creator, each with their role, writers first.
    public var creators: [(role: Role, name: String)] {
        Role.allCases.flatMap { role in (self[keyPath: role.keyPath] ?? []).map { (role, $0) } }
    }

    /// This data's values where it has them, `base`'s elsewhere. Empty text and empty lists
    /// count as no value.
    public func overlaid(on base: BookData) -> BookData {
        func pick<T>(_ a: T?, _ b: T?) -> T? { a ?? b }
        func pickText(_ a: String?, _ b: String?) -> String? { a.flatMap(Self.cleanText) ?? b.flatMap(Self.cleanText) }
        func pickList(_ a: [String]?, _ b: [String]?) -> [String]? {
            if let a, !a.isEmpty { return a }
            if let b, !b.isEmpty { return b }
            return nil
        }
        var result = BookData()
        result.title = pickText(title, base.title)
        result.series = pickText(series, base.series)
        result.number = pickText(number, base.number)
        result.volume = pickText(volume, base.volume)
        result.count = pick(count, base.count)
        result.summary = pickText(summary, base.summary)
        result.year = pick(year, base.year)
        // A date is taken whole, so a month from one place never sits with a year from another.
        if year == nil, base.year != nil {
            result.month = base.month
            result.day = base.day
        } else {
            result.month = month
            result.day = day
        }
        for role in Role.allCases {
            result[keyPath: role.keyPath] = pickList(self[keyPath: role.keyPath], base[keyPath: role.keyPath])
        }
        result.publisher = pickText(publisher, base.publisher)
        result.imprint = pickText(imprint, base.imprint)
        result.genres = pickList(genres, base.genres)
        result.tags = pickList(tags, base.tags)
        result.language = pickText(language, base.language)
        result.ageRating = pickText(ageRating, base.ageRating)
        result.isbn = pickText(isbn, base.isbn)
        result.web = pickText(web, base.web)
        result.rightToLeft = pick(rightToLeft, base.rightToLeft)
        return result
    }

    static func cleanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Splits a list as ComicInfo writes it ("A, B; C") into names.
    public static func names(_ text: String?) -> [String]? {
        guard let text else { return nil }
        let names = text.split(whereSeparator: { ",;、，".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }
}

// MARK: - ComicInfo.xml

public extension BookData {
    /// Every field the library keeps from a ComicInfo.xml (the ComicRack format, also written by
    /// Komga, Kavita and ComicTagger). Returns nil if it is not ComicInfo XML.
    static func comicInfo(_ data: Data) -> BookData? {
        let reader = ComicInfoReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isComicInfo else { return nil }
        let fields = reader.fields
        func text(_ key: String) -> String? { fields[key].flatMap(cleanText) }
        func int(_ key: String) -> Int? {
            guard let value = text(key).flatMap({ Int($0) }), value > 0 else { return nil }
            return value
        }
        var info = BookData()
        info.title = text("title")
        info.series = text("series")
        info.number = text("number").map(Self.trimNumber)
        // ComicRack writes -1 for "no volume".
        if let volume = text("volume") {
            if let n = Int(volume) { info.volume = n >= 0 ? String(n) : nil } else { info.volume = volume }
        }
        info.count = int("count")
        info.summary = text("summary")
        info.year = int("year")
        if info.year != nil {
            info.month = int("month").flatMap { (1...12).contains($0) ? $0 : nil }
            info.day = info.month == nil ? nil : int("day").flatMap { (1...31).contains($0) ? $0 : nil }
        }
        info.writers = names(text("writer"))
        info.pencillers = names(text("penciller"))
        info.inkers = names(text("inker"))
        info.colorists = names(text("colorist"))
        info.letterers = names(text("letterer"))
        info.coverArtists = names(text("coverartist"))
        info.editors = names(text("editor"))
        info.translators = names(text("translator"))
        info.publisher = text("publisher")
        info.imprint = text("imprint")
        info.genres = names(text("genre"))
        info.tags = names(text("tags"))
        info.language = text("languageiso")
        info.ageRating = text("agerating").flatMap { $0.caseInsensitiveCompare("Unknown") == .orderedSame ? nil : $0 }
        info.isbn = text("gtin") ?? text("isbn")
        info.web = text("web")
        if let manga = text("manga") {
            switch manga.lowercased() {
            case "yesandrighttoleft": info.rightToLeft = true
            default: break
            }
        }
        return info
    }

    /// Text that has the look of an entry name for ComicInfo.xml, at any depth, in any case.
    static func isComicInfo(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !path.contains("__MACOSX") else { return false }
        return name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame
    }

    /// "007" is "7", "1.50" stays as written apart from the leading zeros.
    static func trimNumber(_ number: String) -> String {
        var result = Substring(number)
        while result.count > 1, result.first == "0", result.dropFirst().first?.isNumber == true { result = result.dropFirst() }
        return String(result)
    }
}

private final class ComicInfoReader: NSObject, XMLParserDelegate {
    var isComicInfo = false
    var fields: [String: String] = [:]
    private var depth = 0
    private var current: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 1 { isComicInfo = name.caseInsensitiveCompare("ComicInfo") == .orderedSame }
        if depth == 2 {
            current = name.lowercased()
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2, let current, fields[current] == nil { fields[current] = text }
        if depth == 2 { current = nil }
        depth -= 1
    }
}
