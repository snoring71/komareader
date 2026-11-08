import ComicCore
import Foundation
import GRDB

/// One row of the local index. The index is a cache: delete it and it is rebuilt from the
/// library folder and the synced records.
public struct Book: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "book"

    public var id: String
    public var relativePath: String
    public var title: String
    public var folder: String
    public var format: BookFormat
    public var size: Int64?
    public var modified: Date?
    public var isDownloaded: Bool
    public var isMissing: Bool
    public var addedAt: Date
    public var pageCount: Int?
    public var currentPage: Int?
    public var finished: Bool
    public var lastReadAt: Date?
    public var direction: String?

    public enum Status: String, Sendable { case unread, reading, read }

    public var status: Status {
        if finished { return .read }
        if (currentPage ?? 0) > 0 || lastReadAt != nil { return .reading }
        return .unread
    }

    /// 0...1 reading progress, or nil if never opened.
    public var progressFraction: Double? {
        guard let pageCount, pageCount > 1, let currentPage else { return nil }
        if finished { return 1 }
        return min(1, Double(currentPage + 1) / Double(pageCount))
    }
}

extension BookFormat: DatabaseValueConvertible {}

public final class LibraryIndex: @unchecked Sendable {
    public let db: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DatabaseQueue(path: url.path)
        try Self.migrator.migrate(db)
    }

    /// In-memory index, for tests and previews.
    public init() throws {
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "book") { t in
                t.primaryKey("id", .text)
                t.column("relativePath", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("folder", .text).notNull().indexed()
                t.column("format", .text).notNull()
                t.column("size", .integer)
                t.column("modified", .datetime)
                t.column("isDownloaded", .boolean).notNull()
                t.column("isMissing", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
                t.column("pageCount", .integer)
                t.column("currentPage", .integer)
                t.column("finished", .boolean).notNull().defaults(to: false)
                t.column("lastReadAt", .datetime)
                t.column("direction", .text)
            }
        }
        return migrator
    }

    public func allBooks() throws -> [Book] {
        try db.read { db in try Book.fetchAll(db) }
            .sorted { $0.relativePath.naturalLess(than: $1.relativePath) }
    }

    public func book(id: String) throws -> Book? {
        try db.read { db in try Book.fetchOne(db, key: id) }
    }

    public func save(_ book: Book) throws {
        try db.write { db in try book.save(db) }
    }

    /// Brings the index in line with a fresh scan.
    ///
    /// - Known paths are updated in place.
    /// - New paths take the id from a synced record with the same path (another device saw the
    ///   book first), or from a missing book with the same name and size (a move), or get a new id.
    /// - Books no longer found are marked missing, never deleted, so their data is kept.
    @discardableResult
    public func apply(scan: [ScannedBook], records: [BookRecord], now: Date = Date()) throws -> [Book] {
        let recordByPath = Dictionary(records.map { ($0.file.path, $0) }, uniquingKeysWith: { a, _ in a })
        let recordById = Dictionary(records.map { ($0.bookId, $0) }, uniquingKeysWith: { a, _ in a })

        return try db.write { db -> [Book] in
            let existing = try Book.fetchAll(db)
            var byPath = Dictionary(existing.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var takenIds = Set(existing.map(\.id))

            for found in scan {
                var book: Book
                if let current = byPath[found.relativePath] {
                    book = current
                } else if let record = recordByPath[found.relativePath], !seen.contains(record.bookId) {
                    book = try Book.fetchOne(db, key: record.bookId) ?? Self.newBook(id: record.bookId, from: found, now: now)
                } else if let moved = existing.first(where: { $0.isMissing && !seen.contains($0.id) && $0.size == found.size && found.size != nil && $0.title == found.title }) {
                    book = moved
                } else {
                    var id = UUID().uuidString
                    while takenIds.contains(id) { id = UUID().uuidString }
                    book = Self.newBook(id: id, from: found, now: now)
                }
                takenIds.insert(book.id)
                book.relativePath = found.relativePath
                book.title = found.title
                book.folder = found.folder
                book.format = found.format
                book.size = found.size ?? book.size
                book.modified = found.modified ?? book.modified
                book.isDownloaded = found.isDownloaded
                book.isMissing = false
                if let record = recordById[book.id] { Self.applyRecord(record, to: &book) }
                try book.save(db)
                byPath[found.relativePath] = book
                seen.insert(book.id)
            }

            for var book in existing where !seen.contains(book.id) && !book.isMissing {
                book.isMissing = true
                try book.save(db)
            }
            return try Book.fetchAll(db)
        }
    }

    /// Copies synced progress and settings into a row.
    static func applyRecord(_ record: BookRecord, to book: inout Book) {
        if let latest = record.latestProgress?.progress,
           latest.updatedAt > (book.lastReadAt ?? .distantPast) {
            book.currentPage = latest.page
            book.pageCount = latest.pageCount
            book.finished = latest.finished
            book.lastReadAt = latest.updatedAt
        }
        if let direction = record.readerSettings?.direction { book.direction = direction.rawValue }
    }

    private static func newBook(id: String, from found: ScannedBook, now: Date) -> Book {
        Book(
            id: id, relativePath: found.relativePath, title: found.title, folder: found.folder,
            format: found.format, size: found.size, modified: found.modified,
            isDownloaded: found.isDownloaded, isMissing: false, addedAt: now,
            pageCount: nil, currentPage: nil, finished: false, lastReadAt: nil, direction: nil
        )
    }
}
