import Foundation

/// `lists.json`: the library's reading lists (#83) and smart lists (#82). Each list is merged on
/// its own, newest `updatedAt` wins; a deleted list keeps an entry with `deleted: true` so an
/// older copy cannot bring it back.
public struct LibraryLists: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Books put together and ordered by hand.
        case reading
        /// A saved filter, which updates by itself.
        case smart
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        /// A random UUID: lists are made by the user, one device at a time.
        public var id: String
        public var name: String
        public var kind: Kind
        /// A reading list's books, in the user's order. Books that go missing stay in it.
        public var bookIds: [String]?
        /// A smart list's rules.
        public var filter: LibraryFilter?
        /// A smart list's sort order (an app's own name for it, such as "recentlyAdded") and
        /// whether it is ascending.
        public var sort: String?
        public var ascending: Bool?
        /// A smart list shows only its first `limit` books, if set.
        public var limit: Int?
        /// Where the list sits in the sidebar, lowest first.
        public var position: Double
        public var deleted: Bool
        public var updatedAt: Date

        public init(id: String = UUID().uuidString, name: String, kind: Kind, bookIds: [String]? = nil, filter: LibraryFilter? = nil,
                    position: Double, deleted: Bool = false, updatedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.kind = kind
            self.bookIds = bookIds
            self.filter = filter
            self.position = position
            self.deleted = deleted
            self.updatedAt = updatedAt
        }
    }

    public static let currentSchema = 1
    public var schema: Int
    public var lists: [String: Entry]

    public init(lists: [String: Entry] = [:]) {
        self.schema = Self.currentSchema
        self.lists = lists
    }

    /// The lists of one kind that have not been deleted, in sidebar order.
    public func shown(_ kind: Kind) -> [Entry] {
        lists.values.filter { $0.kind == kind && !$0.deleted }
            .sorted { $0.position != $1.position ? $0.position < $1.position : $0.id < $1.id }
    }

    public func list(_ id: String) -> Entry? {
        lists[id].flatMap { $0.deleted ? nil : $0 }
    }

    /// A position after every list of its kind.
    public func nextPosition(_ kind: Kind) -> Double {
        (shown(kind).map(\.position).max() ?? 0) + 1
    }

    public mutating func put(_ entry: Entry, at date: Date = Date()) {
        var entry = entry
        entry.updatedAt = date
        lists[entry.id] = entry
    }

    public mutating func delete(_ id: String, at date: Date = Date()) {
        guard var entry = lists[id] else { return }
        entry.deleted = true
        entry.bookIds = nil
        entry.filter = nil
        entry.updatedAt = date
        lists[id] = entry
    }

    /// Adds books to the end of a reading list, skipping ones already in it.
    public mutating func add(_ bookIds: [String], to id: String, at date: Date = Date()) {
        guard var entry = list(id) else { return }
        var ids = entry.bookIds ?? []
        let have = Set(ids)
        for bookId in bookIds where !have.contains(bookId) && !ids.contains(bookId) { ids.append(bookId) }
        entry.bookIds = ids
        put(entry, at: date)
    }

    /// Moves a list one place up or down among its kind.
    public mutating func move(_ id: String, by offset: Int, at date: Date = Date()) {
        guard let entry = list(id) else { return }
        var order = shown(entry.kind)
        guard let from = order.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        // Whole numbers again, so positions never run out of room.
        for (i, entry) in order.enumerated() where entry.position != Double(i + 1) {
            var item = entry
            item.position = Double(i + 1)
            put(item, at: date)
        }
    }

    public func merged(with other: LibraryLists) -> LibraryLists {
        var result = self
        result.schema = max(schema, other.schema)
        for (key, theirs) in other.lists {
            if let mine = result.lists[key], mine.updatedAt >= theirs.updatedAt { continue }
            result.lists[key] = theirs
        }
        return result
    }
}

/// A filter over the library (#80): the filter bar's chips, a typed search with field prefixes
/// (#81) and a smart list's rules (#82) are all this one value, so it can be saved. Matching is
/// in `LibraryKit` (`Book`) and the app (plain-word search).
public struct LibraryFilter: Codable, Equatable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable, CaseIterable { case all, any }

    public enum Field: String, Codable, Sendable, CaseIterable, Identifiable {
        case title, series, author, publisher, tag, genre, folder, language, format
        case status, favorite, bookmarked, downloaded
        case year, rating, pages
        case added, lastRead, finished
        public var id: String { rawValue }

        public enum Kind: Sendable { case text, list, choice, flag, number, date }

        public var kind: Kind {
            switch self {
            case .title, .series, .author, .publisher, .folder, .language: return .text
            case .tag, .genre: return .list
            case .format, .status: return .choice
            case .favorite, .bookmarked, .downloaded: return .flag
            case .year, .rating, .pages: return .number
            case .added, .lastRead, .finished: return .date
            }
        }

        public var title: String {
            switch self {
            case .title: return "Title"
            case .series: return "Series"
            case .author: return "Author"
            case .publisher: return "Publisher"
            case .tag: return "Tag"
            case .genre: return "Genre"
            case .folder: return "Folder"
            case .language: return "Language"
            case .format: return "Format"
            case .status: return "Status"
            case .favorite: return "Favorite"
            case .bookmarked: return "Bookmarked"
            case .downloaded: return "Downloaded"
            case .year: return "Release Year"
            case .rating: return "Rating"
            case .pages: return "Pages"
            case .added: return "Date Added"
            case .lastRead: return "Last Read"
            case .finished: return "Date Finished"
            }
        }

        /// The comparisons that make sense for the field, the first being the usual one.
        public var operators: [Op] {
            switch kind {
            case .text: return [.contains, .is, .isNot, .beginsWith]
            case .list: return [.isAnyOf, .isAllOf, .isNoneOf]
            case .choice: return [.isAnyOf, .isNoneOf]
            case .flag: return [.isTrue, .isFalse]
            case .number: return [.atLeast, .atMost, .between, .is]
            case .date: return [.inLast, .notInLast, .isSet, .isNotSet]
            }
        }
    }

    public enum Op: String, Codable, Sendable, CaseIterable {
        case contains, `is`, isNot, beginsWith
        case isAnyOf, isAllOf, isNoneOf
        case isTrue, isFalse
        case atLeast, atMost, between
        /// Dates: in the last N days, or not in the last N days (or never).
        case inLast, notInLast, isSet, isNotSet

        public var title: String {
            switch self {
            case .contains: return "contains"
            case .is: return "is"
            case .isNot: return "is not"
            case .beginsWith: return "begins with"
            case .isAnyOf: return "is any of"
            case .isAllOf: return "is all of"
            case .isNoneOf: return "is none of"
            case .isTrue: return "is yes"
            case .isFalse: return "is no"
            case .atLeast: return "is at least"
            case .atMost: return "is at most"
            case .between: return "is between"
            case .inLast: return "in the last"
            case .notInLast: return "not in the last"
            case .isSet: return "is set"
            case .isNotSet: return "is not set"
            }
        }

        /// How many values the comparison takes: 0, 1, 2 or any number (-1).
        public var valueCount: Int {
            switch self {
            case .isTrue, .isFalse, .isSet, .isNotSet: return 0
            case .between: return 2
            case .isAnyOf, .isAllOf, .isNoneOf: return -1
            default: return 1
            }
        }
    }

    public struct Rule: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var field: Field
        public var op: Op
        /// Text, names, numbers or a number of days, as text.
        public var values: [String]

        public init(id: String = UUID().uuidString, _ field: Field, _ op: Op, _ values: [String] = []) {
            self.id = id
            self.field = field
            self.op = op
            self.values = values
        }
    }

    public var match: Match
    public var rules: [Rule]
    /// Plain words, searched in titles, series, authors, publishers, folders and tags.
    public var text: String?

    public init(match: Match = .all, rules: [Rule] = [], text: String? = nil) {
        self.match = match
        self.rules = rules
        self.text = text
    }

    public var isEmpty: Bool { rules.isEmpty && (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

// MARK: - Typed search (#81)

public extension LibraryFilter {
    /// Reads a typed search: `author:天野 year:2010-2015 rating:>=4 is:favorite status:unread
    /// tag:"to read" format:cbz` plus plain words. A value with spaces goes in quotes. Unknown
    /// prefixes are plain words.
    static func parse(_ search: String) -> LibraryFilter {
        var rules: [Rule] = []
        var words: [String] = []
        for token in tokens(search) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                words.append(token)
                continue
            }
            let key = token[..<colon].lowercased()
            let value = unquote(String(token[token.index(after: colon)...]))
            guard !value.isEmpty, let rule = rule(key: key, value: value) else {
                words.append(token)
                continue
            }
            rules.append(rule)
        }
        let text = words.joined(separator: " ")
        return LibraryFilter(match: .all, rules: rules, text: text.isEmpty ? nil : text)
    }

    /// The prefixes a typed search knows, for the suggestions under the search field.
    static let prefixes = ["author:", "publisher:", "series:", "tag:", "genre:", "year:", "rating:", "format:", "status:", "is:", "title:"]

    private static func rule(key: String, value: String) -> Rule? {
        switch key {
        case "author", "writer", "by": return Rule(.author, .contains, [value])
        case "publisher": return Rule(.publisher, .contains, [value])
        case "series": return Rule(.series, .contains, [value])
        case "title": return Rule(.title, .contains, [value])
        case "folder": return Rule(.folder, .contains, [value])
        case "tag": return Rule(.tag, .isAnyOf, [value])
        case "genre": return Rule(.genre, .isAnyOf, [value])
        case "lang", "language": return Rule(.language, .is, [value])
        case "format": return Rule(.format, .isAnyOf, [value.lowercased()])
        case "status":
            let status = value.lowercased()
            guard ["unread", "reading", "read"].contains(status) else { return nil }
            return Rule(.status, .isAnyOf, [status])
        case "is", "not":
            let flag = value.lowercased()
            let negate = key == "not"
            switch flag {
            case "favorite", "favourite", "fav": return Rule(.favorite, negate ? .isFalse : .isTrue)
            case "bookmarked": return Rule(.bookmarked, negate ? .isFalse : .isTrue)
            case "downloaded", "local": return Rule(.downloaded, negate ? .isFalse : .isTrue)
            case "cloud", "icloud": return Rule(.downloaded, negate ? .isTrue : .isFalse)
            case "unread", "reading", "read": return Rule(.status, negate ? .isNoneOf : .isAnyOf, [flag])
            case "rated": return Rule(.rating, negate ? .atMost : .atLeast, [negate ? "0" : "1"])
            default: return nil
            }
        case "year", "rating", "pages":
            let field: Field = key == "year" ? .year : key == "rating" ? .rating : .pages
            return numberRule(field, value)
        default:
            return nil
        }
    }

    /// `2010-2015`, `>=4`, `<=100`, `>3`, `<3`, `2012`.
    private static func numberRule(_ field: Field, _ value: String) -> Rule? {
        let text = value.replacingOccurrences(of: " ", with: "")
        if let dash = text.firstIndex(of: "-"), dash != text.startIndex,
           let low = Int(text[..<dash]), let high = Int(text[text.index(after: dash)...]) {
            return Rule(field, .between, [String(min(low, high)), String(max(low, high))])
        }
        for (prefix, op, shift) in [(">=", Op.atLeast, 0), ("<=", Op.atMost, 0), (">", Op.atLeast, 1), ("<", Op.atMost, -1)] {
            if text.hasPrefix(prefix), let n = Int(text.dropFirst(prefix.count)) { return Rule(field, op, [String(n + shift)]) }
        }
        if let n = Int(text) { return Rule(field, .is, [String(n)]) }
        return nil
    }

    /// Splits on spaces, keeping quoted parts ("to read", author:"Kozue Amano") together.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" || character == "“" || character == "”" {
                quoted.toggle()
                current.append("\"")
            } else if character.isWhitespace, !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func unquote(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
    }
}
