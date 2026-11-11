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
    public var readerSettings: ReaderSettings?
    /// Reading position per device id. Newest entry wins when opening a book.
    public var progress: [String: Progress]

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

    public struct Metadata: Codable, Equatable, Sendable {
        public var series: String?
        public var number: String?
        public var title: String?
        public var writers: [String]
        public var year: Int?
        public var updatedAt: Date

        public init(series: String? = nil, number: String? = nil, title: String? = nil, writers: [String] = [], year: Int? = nil, updatedAt: Date = Date()) {
            self.series = series
            self.number = number
            self.title = title
            self.writers = writers
            self.year = year
            self.updatedAt = updatedAt
        }
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

    /// The most recently updated reading position across all devices.
    public var latestProgress: (device: String, progress: Progress)? {
        progress.max { $0.value.updatedAt < $1.value.updatedAt }.map { ($0.key, $0.value) }
    }

    /// Another device's position worth offering when this device opens the book at `page`:
    /// the newest entry from any other device, if it is newer than this device's own entry,
    /// unfinished, and on a different page.
    public func handOff(for deviceId: String, openingAt page: Int) -> (device: String, progress: Progress)? {
        guard let other = progress.filter({ $0.key != deviceId }).max(by: { $0.value.updatedAt < $1.value.updatedAt }) else { return nil }
        if let mine = progress[deviceId], mine.updatedAt >= other.value.updatedAt { return nil }
        if other.value.finished || other.value.page == page { return nil }
        return (other.key, other.value)
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
        if result.file.fingerprint == nil { result.file.fingerprint = other.file.fingerprint }
        for (device, theirs) in other.progress {
            if let mine = result.progress[device], mine.updatedAt >= theirs.updatedAt { continue }
            result.progress[device] = theirs
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
