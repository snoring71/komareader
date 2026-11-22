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
    public var favorite: Bool
    public var bookmarked: Bool
    /// The user's edit, else the file's ComicInfo.xml, else worked out from the file name
    /// (see `refreshInfo`).
    public var series: String
    public var number: String?
    /// The user's own tags, from the synced record, in the user's spelling.
    public var tags: [String] = []
    /// The authors (joined with commas), publisher and title from `info`, kept as columns of
    /// their own for older versions of the app.
    public var author: String?
    public var publisher: String?
    public var metadataTitle: String?
    /// True once the file's metadata has been read (whether or not it had any).
    public var metadataRead: Bool = false
    /// Pages bookmarked in the reader, from the synced record (`BookRecord.pageBookmarks`).
    public var pageBookmarks: [Int] = []
    /// What the file itself says (ComicInfo.xml, or a PDF's attributes), once read on this
    /// device (#75). Nil until then, or when the file says nothing.
    public var fileData: BookData?
    /// The user's own edits, from the synced record's `metadata` group (#76).
    public var userData: BookData?
    /// What the library shows: the user's edits, else the file's data, else what the file name
    /// says (#77). Worked out by `refreshInfo`.
    public var info = BookData()

    /// One to five stars, from the synced record (#84).
    public var rating: Int?

    /// The authors the library files the book under (#78).
    public var authors: [String] { info.authors }

    /// Works out `info`, and the series, number, author, publisher and title columns, from the
    /// three places they can come from.
    public mutating func refreshInfo(rules: FileNameRules) {
        let fromName = FileNameReader.read(title, folder: folder, rules: rules)
        var merged = (fileData ?? BookData()).overlaid(on: fromName)
        // The file's own tags are kept, but the user's tags are what the library shows as tags.
        merged = (userData ?? BookData()).overlaid(on: merged)
        info = merged
        series = merged.series ?? title
        number = merged.number
        author = merged.authors.isEmpty ? nil : merged.authors.joined(separator: ", ")
        publisher = merged.publisher
        metadataTitle = merged.title
    }

    /// What the book would show without the user's edits: the file's data, else the file name's.
    public func baseInfo(rules: FileNameRules) -> BookData {
        (fileData ?? BookData()).overlaid(on: FileNameReader.read(title, folder: folder, rules: rules))
    }

    /// Takes the values `refreshInfo` works out from another copy of the same book.
    public mutating func copyInfo(from other: Book) {
        info = other.info
        series = other.series
        number = other.number
        author = other.author
        publisher = other.publisher
        metadataTitle = other.metadataTitle
    }

    /// Shown under Bookmarked: the book itself is marked, or it has a bookmarked page.
    public var hasBookmarks: Bool { bookmarked || !pageBookmarks.isEmpty }

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
        migrator.registerMigration("v2") { db in
            try db.alter(table: "book") { t in
                t.add(column: "favorite", .boolean).notNull().defaults(to: false)
                t.add(column: "bookmarked", .boolean).notNull().defaults(to: false)
                t.add(column: "series", .text).notNull().defaults(to: "")
                t.add(column: "number", .text)
            }
        }
        // Two branches each added a "v3" (file metadata here, tags in the other), and a device
        // that ran one build and then the other found "v3" done but its columns missing. So
        // "v3" and "v4" both add whichever of those columns are missing, and do nothing else:
        // any device, whichever build it ran, ends up with all of them.
        migrator.registerMigration("v3") { db in try addMissingColumns(db) }
        migrator.registerMigration("v4") { db in try addMissingColumns(db) }
        // Named for what it adds rather than "v3", so it cannot clash with a migration added
        // on another branch: a database that already ran another "v3" would skip it and then
        // fail to read any book.
        migrator.registerMigration("tags") { db in
            // A test build from this branch named this migration "v3"; that copy may have run.
            guard try !db.columns(in: "book").contains(where: { $0.name == "tags" }) else { return }
            try db.alter(table: "book") { t in
                // A JSON array of strings.
                t.add(column: "tags", .text).notNull().defaults(to: "[]")
            }
        }
        // Named for what it adds (and its issue) rather than "v3": other branches add their
        // own migrations, and a database that had already run another branch's "v3" would
        // skip one of the same name and then fail to read any book. It also checks for the
        // column, so a device that ran any mix of branches still opens.
        migrator.registerMigration("page-bookmarks-54") { db in
            guard try !db.columns(in: "book").contains(where: { $0.name.lowercased() == "pagebookmarks" }) else { return }
            try db.alter(table: "book") { t in
                // A JSON array of page indexes.
                t.add(column: "pageBookmarks", .text).notNull().defaults(to: "[]")
            }
        }
        // Every ComicInfo.xml field (#75), the user's edits (#76) and the two merged. Named for
        // its issue so no other branch's migration can share its name, and it checks for its
        // columns, so a device that ran any mix of test builds still opens.
        migrator.registerMigration("book-data-75") { db in
            let existing = Set(try db.columns(in: "book").map { $0.name.lowercased() })
            let wanted: [(name: String, add: (TableAlteration) -> Void)] = [
                ("fileData", { $0.add(column: "fileData", .text) }),
                ("userData", { $0.add(column: "userData", .text) }),
                ("info", { $0.add(column: "info", .text).notNull().defaults(to: "{}") }),
            ]
            let missing = wanted.filter { !existing.contains($0.name.lowercased()) }
            if !missing.isEmpty {
                try db.alter(table: "book") { t in
                    for column in missing { column.add(t) }
                }
            }
            // Read every file's metadata again, now that all of it is kept.
            try db.execute(sql: "UPDATE book SET metadataRead = 0")
        }
        // Star ratings (#84), named for its issue and guarded like the others.
        migrator.registerMigration("ratings-84") { db in
            guard try !db.columns(in: "book").contains(where: { $0.name.lowercased() == "rating" }) else { return }
            try db.alter(table: "book") { t in t.add(column: "rating", .integer) }
        }
        return migrator
    }

    /// The columns added after v2, added only where they are not there yet.
    private static func addMissingColumns(_ db: Database) throws {
        let existing = Set(try db.columns(in: "book").map { $0.name.lowercased() })
        let wanted: [(name: String, add: (TableAlteration) -> Void)] = [
            // A JSON array of strings (user tags).
            ("tags", { $0.add(column: "tags", .text).notNull().defaults(to: "[]") }),
            ("author", { $0.add(column: "author", .text) }),
            ("publisher", { $0.add(column: "publisher", .text) }),
            ("metadataTitle", { $0.add(column: "metadataTitle", .text) }),
            ("metadataRead", { $0.add(column: "metadataRead", .boolean).notNull().defaults(to: false) }),
        ]
        let missing = wanted.filter { !existing.contains($0.name.lowercased()) }
        guard !missing.isEmpty else { return }
        try db.alter(table: "book") { t in
            for column in missing { column.add(t) }
        }
    }

    public func allBooks() throws -> [Book] {
        try db.read { db in try Book.fetchAll(db) }
            .filter { $0.format.isEnabled }
            .naturallySorted(by: \.relativePath)
    }

    public func book(id: String) throws -> Book? {
        try db.read { db in try Book.fetchOne(db, key: id) }
    }

    public func save(_ book: Book) throws {
        try db.write { db in try book.save(db) }
    }

    /// Saves several books in one transaction.
    public func save(_ books: [Book]) throws {
        guard !books.isEmpty else { return }
        try db.write { db in
            for book in books { try book.save(db) }
        }
    }

    /// Removes books from the index (used to delete missing books from the library).
    public func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in _ = try Book.deleteAll(db, keys: ids) }
    }

    /// Stores what was read from the files (#75) and works out each row's data again, in one
    /// transaction. Rows are read and written inside it, so nothing else in them is lost.
    @discardableResult
    public func saveFileData(_ items: [String: BookData], rules: FileNameRules = .standard) throws -> [Book] {
        guard !items.isEmpty else { return [] }
        return try db.write { db in
            var saved: [Book] = []
            for (id, data) in items {
                guard var book = try Book.fetchOne(db, key: id) else { continue }
                book.fileData = data.isEmpty ? nil : data
                book.metadataRead = true
                book.refreshInfo(rules: rules)
                try book.update(db)
                saved.append(book)
            }
            return saved
        }
    }

    /// Stores a book's bookmarked pages without touching the rest of its row (the reader
    /// changes them while the library holds an older copy of the row).
    public func setPageBookmarks(_ pages: [Int], bookId: String) throws {
        let json = String(decoding: try JSONEncoder().encode(pages), as: UTF8.self)
        try db.write { db in
            _ = try Book.filter(key: bookId).updateAll(db, Column("pageBookmarks").set(to: json))
        }
    }

    /// Brings the index in line with a fresh scan.
    ///
    /// - Known paths are updated in place.
    /// - New paths take the id from a synced record with the same path (another device saw the
    ///   book first), or from a missing book with the same name and size (a move), or get the id
    ///   worked out from the path (`StableID.book`).
    /// - Known paths whose book has no synced record switch to the id of a record with the same
    ///   path, if one has arrived.
    /// - Books no longer found are marked missing, never deleted, so their data is kept, except
    ///   books the user deleted from the library (on any device, see `BookRecord.isRemoved`)
    ///   and books in formats that are switched off (`BookFormat.isEnabled`), which are dropped.
    @discardableResult
    public func apply(scan: [ScannedBook], records: [BookRecord], rules: FileNameRules = .standard, now: Date = Date()) throws -> [Book] {
        // If two records still share a path, every device picks the same one (the lower id).
        let recordByPath = Dictionary(records.map { ($0.file.path, $0) }, uniquingKeysWith: { a, b in a.bookId <= b.bookId ? a : b })
        let recordById = Dictionary(records.map { ($0.bookId, $0) }, uniquingKeysWith: { a, _ in a })

        return try db.write { db -> [Book] in
            let existing = try Book.fetchAll(db)
            var byPath = Dictionary(existing.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var takenIds = Set(existing.map(\.id))

            for found in scan {
                var book: Book
                // The row as the index holds it, so a book nothing changed for is not written
                // again: every rescan used to rewrite every row.
                var stored: Book?
                if var current = byPath[found.relativePath] {
                    stored = current
                    // This device gave the book its own id before another device's record for the
                    // same file arrived (or duplicates were folded into another id). Take the
                    // synced id so both devices share progress and settings from now on.
                    if recordById[current.id] == nil, let record = recordByPath[found.relativePath],
                       record.bookId != current.id, !seen.contains(record.bookId),
                       record.file.size == nil || found.size == nil || record.file.size == found.size,
                       try Book.fetchOne(db, key: record.bookId) == nil {
                        try Book.deleteOne(db, key: current.id)
                        seen.insert(current.id)
                        current.id = record.bookId
                    }
                    book = current
                } else if let record = recordByPath[found.relativePath], !seen.contains(record.bookId) {
                    stored = try Book.fetchOne(db, key: record.bookId)
                    book = stored ?? Self.newBook(id: record.bookId, from: found, now: now)
                } else if let moved = existing.first(where: { $0.isMissing && !seen.contains($0.id) && $0.size == found.size && found.size != nil && $0.title == found.title && recordById[$0.id]?.isRemoved != true }) {
                    stored = moved
                    book = moved
                } else {
                    // The same id another device works out for this path, so records written
                    // before either device has seen the other's still line up.
                    var id = StableID.book(path: found.relativePath)
                    while takenIds.contains(id) { id = UUID().uuidString }
                    book = Self.newBook(id: id, from: found, now: now)
                }
                takenIds.insert(book.id)
                book.relativePath = found.relativePath
                book.title = found.title
                book.folder = found.folder
                book.format = found.format
                // A changed file may carry changed metadata: read it again.
                // (The index keeps dates to the millisecond, so allow for rounding.)
                if let new = found.modified, abs(new.timeIntervalSince(book.modified ?? .distantPast)) > 1 { book.metadataRead = false }
                book.size = found.size ?? book.size
                book.modified = found.modified ?? book.modified
                book.isDownloaded = found.isDownloaded
                book.isMissing = false
                if let record = recordById[book.id] { Self.applyRecord(record, to: &book) }
                book.refreshInfo(rules: rules)
                if !Self.sameRow(book, stored) { try book.save(db) }
                byPath[found.relativePath] = book
                seen.insert(book.id)
            }

            for var book in existing where !seen.contains(book.id) {
                if !book.format.isEnabled || recordById[book.id]?.isRemoved == true {
                    try Book.deleteOne(db, key: book.id)
                } else if !book.isMissing {
                    book.isMissing = true
                    try book.save(db)
                }
            }
            return try Book.fetchAll(db)
        }
    }

    /// Whether saving `book` would leave `stored` as it is. The index keeps dates to the
    /// millisecond, so a date read back from it is a fraction off the file's own.
    static func sameRow(_ book: Book, _ stored: Book?) -> Bool {
        guard let stored else { return false }
        // Within a millisecond counts as the same date.
        func close(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return abs(a.timeIntervalSince(b)) < 0.001
        }
        guard close(book.modified, stored.modified), close(book.lastReadAt, stored.lastReadAt),
              close(book.addedAt, stored.addedAt) else { return false }
        var same = book
        same.modified = stored.modified
        same.lastReadAt = stored.lastReadAt
        same.addedAt = stored.addedAt
        return same == stored
    }

    /// Copies synced progress and settings into a row.
    static func applyRecord(_ record: BookRecord, to book: inout Book) {
        if let latest = record.latestProgress?.progress,
           latest.updatedAt > (book.lastReadAt ?? .distantPast) {
            book.currentPage = latest.page
            book.pageCount = latest.pageCount
            book.finished = latest.finished
            book.lastReadAt = latest.updatedAt
        } else if record.wasReset(after: book.lastReadAt) {
            // Marked unread on some device: as if never opened.
            book.currentPage = nil
            book.finished = false
            book.lastReadAt = nil
        }
        // The book's own direction; nil follows the default for books.
        if let options = record.readerOptions {
            book.direction = options.direction?.rawValue
        } else if let direction = record.readerSettings?.direction {
            book.direction = direction.rawValue
        }
        if let flags = record.flags {
            book.favorite = flags.favorite
            book.bookmarked = flags.bookmarked
        }
        if let tags = record.tags {
            book.tags = tags.value
        }
        if let bookmarks = record.pageBookmarks {
            book.pageBookmarks = bookmarks.pages
        }
        if let rating = record.rating {
            book.rating = rating.value
        }
        // The user's edits; `refreshInfo` puts them on top of the file's data.
        if let metadata = record.metadata {
            let values = metadata.values
            book.userData = values.isEmpty ? nil : values
        }
    }

    private static func newBook(id: String, from found: ScannedBook, now: Date) -> Book {
        Book(
            id: id, relativePath: found.relativePath, title: found.title, folder: found.folder,
            format: found.format, size: found.size, modified: found.modified,
            isDownloaded: found.isDownloaded, isMissing: false, addedAt: now,
            pageCount: nil, currentPage: nil, finished: false, lastReadAt: nil, direction: nil,
            favorite: false, bookmarked: false, series: found.title, number: nil,
            author: nil, publisher: nil, metadataTitle: nil, metadataRead: false
        )
    }
}
