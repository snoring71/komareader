import Foundation

/// One book's synced data, stored as `books/<bookId>.json` in the app's iCloud folder.
/// This is the open format shared with other apps (see docs/SCHEMA.md); keep it stable.
public struct BookRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var bookId: String
    public var file: FileInfo
    public var metadata: Metadata?
    public var tags: Tags?
    public var cover: CoverEdit?
    public var flags: Flags?
    /// Reading direction only, as written by version 0.1. Kept up to date for older versions;
    /// `readerOptions` takes over once it is present.
    public var readerSettings: ReaderSettings?
    /// The book's own reader settings (direction, layout, fit, background, crop and so on).
    public var readerOptions: ReaderOptions?
    /// Reading position per device id. Newest entry wins when opening a book.
    public var progress: [String: Progress]
    /// Set when the book was marked unread. Progress entries from before it are ignored on
    /// every device.
    public var progressReset: ProgressReset?
    /// The pages the user bookmarked in the reader.
    public var pageBookmarks: PageBookmarks?
    /// Set when the user deletes the book from the library after its file went missing.
    /// See `isRemoved`.
    public var removed: Removed?
    /// The user's star rating (#84).
    public var rating: Rating?

    public init(bookId: String, file: FileInfo) {
        self.schema = Self.currentSchema
        self.bookId = bookId
        self.file = file
        self.progress = [:]
    }

    public struct FileInfo: Codable, Equatable, Sendable {
        /// Path relative to the library folder, with "/" separators.
        public var path: String
        public var size: Int64?
        public var modified: Date?
        /// Hex digest of the first and last 64 KB, set once the book has been opened.
        public var fingerprint: String?

        public init(path: String, size: Int64?, modified: Date?, fingerprint: String? = nil) {
            self.path = path
            self.size = size
            self.modified = modified
            self.fingerprint = fingerprint
        }
    }

    /// The user's own edits to the book's data (#76). A field that is nil (or an empty list)
    /// has no edit, and shows what the file or its name says. The whole group merges as one,
    /// newest `updatedAt` wins. `writers` is always written, as version 0.1 requires it.
    public struct Metadata: Codable, Equatable, Sendable {
        public var series: String?
        public var number: String?
        public var title: String?
        public var writers: [String]
        public var year: Int?
        public var volume: String?
        public var count: Int?
        public var summary: String?
        public var month: Int?
        public var day: Int?
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
        public var language: String?
        public var ageRating: String?
        public var isbn: String?
        public var web: String?
        public var updatedAt: Date

        public init(series: String? = nil, number: String? = nil, title: String? = nil, writers: [String] = [], year: Int? = nil, updatedAt: Date = Date()) {
            self.series = series
            self.number = number
            self.title = title
            self.writers = writers
            self.year = year
            self.updatedAt = updatedAt
        }

        public init(_ values: BookData, updatedAt: Date = Date()) {
            self.init(updatedAt: updatedAt)
            self.values = values
        }

        /// The edits as book data (no file tags or direction: those are not edited here).
        public var values: BookData {
            get {
                var data = BookData()
                data.series = series
                data.number = number
                data.title = title
                data.writers = writers.isEmpty ? nil : writers
                data.year = year
                data.volume = volume
                data.count = count
                data.summary = summary
                data.month = month
                data.day = day
                data.pencillers = pencillers
                data.inkers = inkers
                data.colorists = colorists
                data.letterers = letterers
                data.coverArtists = coverArtists
                data.editors = editors
                data.translators = translators
                data.publisher = publisher
                data.imprint = imprint
                data.genres = genres
                data.language = language
                data.ageRating = ageRating
                data.isbn = isbn
                data.web = web
                return data
            }
            set {
                func text(_ value: String?) -> String? { value.flatMap(BookData.cleanText) }
                func list(_ value: [String]?) -> [String]? {
                    let names = (value ?? []).compactMap(BookData.cleanText)
                    return names.isEmpty ? nil : names
                }
                series = text(newValue.series)
                number = text(newValue.number)
                title = text(newValue.title)
                writers = list(newValue.writers) ?? []
                year = newValue.year
                volume = text(newValue.volume)
                count = newValue.count
                summary = text(newValue.summary)
                month = newValue.month
                day = newValue.day
                pencillers = list(newValue.pencillers)
                inkers = list(newValue.inkers)
                colorists = list(newValue.colorists)
                letterers = list(newValue.letterers)
                coverArtists = list(newValue.coverArtists)
                editors = list(newValue.editors)
                translators = list(newValue.translators)
                publisher = text(newValue.publisher)
                imprint = text(newValue.imprint)
                genres = list(newValue.genres)
                language = text(newValue.language)
                ageRating = text(newValue.ageRating)
                isbn = text(newValue.isbn)
                web = text(newValue.web)
            }
        }
    }

    /// One to five stars (#84). Removing a rating writes the group with no value, so the
    /// removal syncs and wins over an older rating.
    public struct Rating: Codable, Equatable, Sendable {
        public var value: Int?
        public var updatedAt: Date
        public init(value: Int?, updatedAt: Date = Date()) {
            self.value = value.flatMap { (1...5).contains($0) ? $0 : nil }
            self.updatedAt = updatedAt
        }
    }

    /// The book was deleted from the library (only offered once its file is missing).
    public struct Removed: Codable, Equatable, Sendable {
        public var updatedAt: Date
        public init(updatedAt: Date = Date()) { self.updatedAt = updatedAt }
    }

    /// True while the deletion is the newest thing that happened to the book. Anything set
    /// later (reading it, a Favorite) means the book came back, so it counts as not removed.
    public var isRemoved: Bool {
        guard let removed else { return false }
        let others: [Date?] = [
            metadata?.updatedAt, tags?.updatedAt, cover?.updatedAt, flags?.updatedAt,
            readerSettings?.updatedAt, readerOptions?.updatedAt, latestProgress?.progress.updatedAt,
            progressReset?.updatedAt, pageBookmarks?.updatedAt, rating?.updatedAt,
        ]
        return others.allSatisfy { ($0 ?? .distantPast) <= removed.updatedAt }
    }

    public struct Tags: Codable, Equatable, Sendable {
        public var value: [String]
        public var updatedAt: Date
        public init(value: [String], updatedAt: Date = Date()) {
            self.value = value
            self.updatedAt = updatedAt
        }
    }

    public struct CoverEdit: Codable, Equatable, Sendable {
        public var page: Int
        /// x, y, width, height as fractions of the page.
        public var crop: [Double]
        /// Degrees clockwise: 0, 90, 180 or 270.
        public var rotation: Int
        public var updatedAt: Date
        public init(page: Int, crop: [Double] = [0, 0, 1, 1], rotation: Int = 0, updatedAt: Date = Date()) {
            self.page = page
            self.crop = crop
            self.rotation = rotation
            self.updatedAt = updatedAt
        }

        /// The first page, uncropped and upright: the same as having no edit.
        public var isDefault: Bool { page == 0 && rotation % 360 == 0 && crop == [0, 0, 1, 1] }
    }

    /// The user's own marks on a book: Favorite and Bookmarked.
    public struct Flags: Codable, Equatable, Sendable {
        public var favorite: Bool
        public var bookmarked: Bool
        public var updatedAt: Date
        public init(favorite: Bool = false, bookmarked: Bool = false, updatedAt: Date = Date()) {
            self.favorite = favorite
            self.bookmarked = bookmarked
            self.updatedAt = updatedAt
        }
    }

    /// The moment reading progress was reset: see `progressReset`.
    public struct ProgressReset: Codable, Equatable, Sendable {
        public var updatedAt: Date
        public init(updatedAt: Date = Date()) { self.updatedAt = updatedAt }
    }

    /// Bookmarked pages: zero-based page indexes, sorted, no duplicates. The whole list is
    /// one group, so the newest list wins.
    public struct PageBookmarks: Codable, Equatable, Sendable {
        public var pages: [Int]
        public var updatedAt: Date
        public init(pages: [Int], updatedAt: Date = Date()) {
            self.pages = Array(Set(pages.filter { $0 >= 0 })).sorted()
            self.updatedAt = updatedAt
        }
    }

    public struct ReaderSettings: Codable, Equatable, Sendable {
        public enum Direction: String, Codable, Sendable { case leftToRight = "ltr", rightToLeft = "rtl" }
        public enum Layout: String, Codable, Sendable { case auto, single, double }
        public var direction: Direction
        public var layout: Layout
        public var updatedAt: Date
        public init(direction: Direction = .leftToRight, layout: Layout = .auto, updatedAt: Date = Date()) {
            self.direction = direction
            self.layout = layout
            self.updatedAt = updatedAt
        }
    }

    public struct Progress: Codable, Equatable, Sendable {
        /// Zero-based index of the first page on screen.
        public var page: Int
        public var pageCount: Int
        public var finished: Bool
        public var updatedAt: Date
        public init(page: Int, pageCount: Int, finished: Bool, updatedAt: Date = Date()) {
            self.page = page
            self.pageCount = pageCount
            self.finished = finished
            self.updatedAt = updatedAt
        }
    }

    /// Progress entries that count: those saved after the last reset, if there was one.
    public var currentProgress: [String: Progress] {
        guard let reset = progressReset?.updatedAt else { return progress }
        return progress.filter { $0.value.updatedAt > reset }
    }

    /// The most recently updated reading position across all devices (since the last reset).
    public var latestProgress: (device: String, progress: Progress)? {
        currentProgress.max { $0.value.updatedAt < $1.value.updatedAt }.map { ($0.key, $0.value) }
    }

    /// True when the last thing that happened to the book's progress was a reset, newer than
    /// `date` (the time this device last saw the book read). The book should then show as
    /// never opened.
    public func wasReset(after date: Date?) -> Bool {
        guard let reset = progressReset?.updatedAt, latestProgress == nil else { return false }
        return reset > (date ?? .distantPast)
    }

    /// Resets reading progress on every device: entries are dropped from this copy, and the
    /// reset date makes copies of them that come back in a merge count for nothing.
    public mutating func resetProgress(at date: Date = Date()) {
        progressReset = ProgressReset(updatedAt: date)
        progress = [:]
    }

    /// Another device's position worth offering when this device opens the book at `page`:
    /// the furthest unfinished position any other device has reached beyond `page`. The book
    /// opens at the newest position (`latestProgress`); this catches the case where you read
    /// further on one device and later glanced at an earlier page on another.
    public func handOff(for deviceId: String, openingAt page: Int) -> (device: String, progress: Progress)? {
        let ahead = currentProgress.filter { $0.key != deviceId && !$0.value.finished && $0.value.page > page }
        guard let best = ahead.max(by: { a, b in
            a.value.page != b.value.page ? a.value.page < b.value.page : a.value.updatedAt < b.value.updatedAt
        }) else { return nil }
        return (best.key, best.value)
    }
}

// MARK: - Merge

public extension BookRecord {
    /// Merges two copies of the same book's record (for example a local edit and an iCloud
    /// conflict version). Each field group keeps whichever side changed it last; progress is
    /// merged per device. Ties keep `self`.
    func merged(with other: BookRecord) -> BookRecord {
        var result = self
        result.schema = max(schema, other.schema)
        result.metadata = Self.newer(metadata, other.metadata) { $0.updatedAt }
        result.tags = Self.newer(tags, other.tags) { $0.updatedAt }
        result.cover = Self.newer(cover, other.cover) { $0.updatedAt }
        result.flags = Self.newer(flags, other.flags) { $0.updatedAt }
        result.readerSettings = Self.newer(readerSettings, other.readerSettings) { $0.updatedAt }
        result.readerOptions = Self.newer(readerOptions, other.readerOptions) { $0.updatedAt }
        result.progressReset = Self.newer(progressReset, other.progressReset) { $0.updatedAt }
        result.pageBookmarks = Self.newer(pageBookmarks, other.pageBookmarks) { $0.updatedAt }
        result.removed = Self.newer(removed, other.removed) { $0.updatedAt }
        result.rating = Self.newer(rating, other.rating) { $0.updatedAt }
        if result.file.fingerprint == nil { result.file.fingerprint = other.file.fingerprint }
        for (device, theirs) in other.progress {
            if let mine = result.progress[device], mine.updatedAt >= theirs.updatedAt { continue }
            result.progress[device] = theirs
        }
        // Entries from before the reset are dead weight once it is known.
        if let reset = result.progressReset?.updatedAt {
            result.progress = result.progress.filter { $0.value.updatedAt > reset }
        }
        return result
    }

    private static func newer<T>(_ a: T?, _ b: T?, date: (T) -> Date) -> T? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return date(b) > date(a) ? b : a
        }
    }
}

// MARK: - Coding

public enum RecordCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) ?? plainFormatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(string)")
        }
        return decoder
    }

    // ISO 8601 in UTC with milliseconds, e.g. 2026-10-02T18:11:04.120Z.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
