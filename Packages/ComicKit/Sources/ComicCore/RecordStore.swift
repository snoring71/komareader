import Foundation

/// Reads and writes one library's open data folder:
///
///     Libraries/<libraryId>/
///       library.json
///       books/<bookId>.json
///       covers/<bookId>.jpg
///       covers/<bookId>.custom.jpg
///
/// All writes are atomic and go through NSFileCoordinator, and records are merged with
/// whatever is already on disk (and any iCloud conflict versions) so no device's edits are lost.
public final class RecordStore: @unchecked Sendable {
    public let root: URL
    public let info: LibraryInfo
    public var booksDirectory: URL { root.appendingPathComponent("books", isDirectory: true) }
    public var coversDirectory: URL { root.appendingPathComponent("covers", isDirectory: true) }

    private let fileManager = FileManager()

    public init(root: URL, info: LibraryInfo) throws {
        self.root = root
        self.info = info
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
    }

    /// Finds the data folder for a library folder name under `dataRoot/Libraries`, or creates one.
    public static func open(dataRoot: URL, folderName: String) throws -> RecordStore {
        let libraries = dataRoot.appendingPathComponent("Libraries", isDirectory: true)
        let fm = FileManager()
        try fm.createDirectory(at: libraries, withIntermediateDirectories: true)
        let decoder = RecordCoding.decoder()
        let candidates = (try? fm.contentsOfDirectory(at: libraries, includingPropertiesForKeys: nil)) ?? []
        for dir in candidates {
            let infoURL = dir.appendingPathComponent("library.json")
            if let data = Self.coordinatedRead(infoURL),
               let info = try? decoder.decode(LibraryInfo.self, from: data),
               info.folderName == folderName {
                return try RecordStore(root: dir, info: info)
            }
        }
        let info = LibraryInfo(folderName: folderName)
        let dir = libraries.appendingPathComponent(info.libraryId, isDirectory: true)
        let store = try RecordStore(root: dir, info: info)
        try Self.coordinatedWrite(try RecordCoding.encoder().encode(info), to: dir.appendingPathComponent("library.json"))
        try store.writeSchemaDoc(into: dataRoot)
        return store
    }

    // MARK: Records

    public func recordURL(bookId: String) -> URL {
        booksDirectory.appendingPathComponent("\(bookId).json")
    }

    public func read(bookId: String) -> BookRecord? {
        let url = recordURL(bookId: bookId)
        resolveConflicts(at: url)
        guard let data = Self.coordinatedRead(url) else { return nil }
        return try? RecordCoding.decoder().decode(BookRecord.self, from: data)
    }

    /// Merges `record` with the copy on disk and writes the result. Returns what was written.
    @discardableResult
    public func write(_ record: BookRecord) throws -> BookRecord {
        var merged = record
        if let existing = read(bookId: record.bookId) {
            merged = record.merged(with: existing)
            merged.file = record.file
        }
        try Self.coordinatedWrite(try RecordCoding.encoder().encode(merged), to: recordURL(bookId: record.bookId))
        return merged
    }

    /// Every record in the folder. Files still in iCloud only are skipped (they arrive later).
    public func allRecords() -> [BookRecord] {
        let decoder = RecordCoding.decoder()
        let urls = (try? fileManager.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(BookRecord.self, from: data)
        }
    }

    // MARK: Covers

    public func coverURL(bookId: String, custom: Bool = false) -> URL {
        coversDirectory.appendingPathComponent(custom ? "\(bookId).custom.jpg" : "\(bookId).jpg")
    }

    /// The cover to show: the user's edited cover if there is one, else the default cover.
    public func existingCoverURL(bookId: String) -> URL? {
        for custom in [true, false] {
            let url = coverURL(bookId: bookId, custom: custom)
            if fileManager.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    public func writeCover(_ jpeg: Data, bookId: String, custom: Bool = false) throws {
        try Self.coordinatedWrite(jpeg, to: coverURL(bookId: bookId, custom: custom))
    }

    // MARK: File coordination

    static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = try? Data(contentsOf: url)
        }
        return result
    }

    static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    /// Folds any iCloud conflict versions of a record into the current file, then clears them.
    private func resolveConflicts(at url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty,
              let currentData = Self.coordinatedRead(url) else { return }
        let decoder = RecordCoding.decoder()
        guard var current = try? decoder.decode(BookRecord.self, from: currentData) else { return }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url),
               let other = try? decoder.decode(BookRecord.self, from: data) {
                current = current.merged(with: other)
            }
        }
        do {
            try Self.coordinatedWrite(try RecordCoding.encoder().encode(current), to: url)
            for version in conflicts { version.isResolved = true }
            try NSFileVersion.removeOtherVersionsOfItem(at: url)
        } catch {
            // Leave conflicts in place; we will try again on the next read.
        }
    }

    private func writeSchemaDoc(into dataRoot: URL) throws {
        let url = dataRoot.appendingPathComponent("SCHEMA.md")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try Self.coordinatedWrite(Data(SchemaDoc.markdown.utf8), to: url)
    }
}
