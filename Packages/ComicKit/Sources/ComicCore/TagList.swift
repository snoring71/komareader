import Foundation

/// `tags.json`: the library's tags, so a tag stays (with no books) until the user deletes it.
/// Each tag is keyed by its lower-cased name and merged on its own, newest `updatedAt` wins; a
/// deleted tag keeps an entry with `deleted: true` so an older copy cannot bring it back.
public struct TagList: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The user's spelling.
        public var name: String
        public var deleted: Bool
        public var updatedAt: Date

        public init(name: String, deleted: Bool = false, updatedAt: Date = Date()) {
            self.name = name
            self.deleted = deleted
            self.updatedAt = updatedAt
        }
    }

    public static let currentSchema = 1
    public var schema: Int
    public var tags: [String: Entry]

    public init(tags: [String: Entry] = [:]) {
        self.schema = Self.currentSchema
        self.tags = tags
    }

    public static func key(_ name: String) -> String { name.lowercased() }

    /// The tags that have not been deleted, in the user's spelling.
    public var names: [String] { tags.values.filter { !$0.deleted }.map(\.name) }

    public func contains(_ name: String) -> Bool { tags[Self.key(name)].map { !$0.deleted } ?? false }

    /// Adds a tag, or brings back a deleted one.
    public mutating func add(_ name: String, at date: Date = Date()) {
        tags[Self.key(name)] = Entry(name: name, updatedAt: date)
    }

    /// Adds a tag only if the list has never had it (not even as deleted).
    public mutating func keep(_ name: String, at date: Date = Date()) {
        if tags[Self.key(name)] == nil { add(name, at: date) }
    }

    public mutating func remove(_ name: String, at date: Date = Date()) {
        tags[Self.key(name)] = Entry(name: tags[Self.key(name)]?.name ?? name, deleted: true, updatedAt: date)
    }

    public func merged(with other: TagList) -> TagList {
        var result = self
        result.schema = max(schema, other.schema)
        for (key, theirs) in other.tags {
            if let mine = result.tags[key], mine.updatedAt >= theirs.updatedAt { continue }
            result.tags[key] = theirs
        }
        return result
    }
}
