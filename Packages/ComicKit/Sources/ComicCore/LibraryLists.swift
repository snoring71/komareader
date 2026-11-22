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

/// A placeholder for the filter a smart list saves; filled in with the filter bar (#80).
public struct LibraryFilter: Codable, Equatable, Hashable, Sendable {
    public init() {}
}
