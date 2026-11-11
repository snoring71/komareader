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
    ///
    /// A new library gets an id worked out from the folder name (`StableID`), so two devices that
    /// pick the same folder before iCloud has synced end up in the same data folder. If several
    /// data folders do claim the same folder name, every device keeps the same one (the one with
    /// the worked-out id, else the lowest id) and merges the others into it. The others are left
    /// in place, so a device still writing to one loses nothing; merging again is harmless.
    public static func open(dataRoot: URL, folderName: String) throws -> RecordStore {
        let libraries = dataRoot.appendingPathComponent("Libraries", isDirectory: true)
        let fm = FileManager()
        try fm.createDirectory(at: libraries, withIntermediateDirectories: true)
        let decoder = RecordCoding.decoder()
        let candidates = (try? fm.contentsOfDirectory(at: libraries, includingPropertiesForKeys: nil)) ?? []
        var matches: [(dir: URL, info: LibraryInfo)] = []
        for dir in candidates {
            let infoURL = dir.appendingPathComponent("library.json")
            if let data = Self.coordinatedRead(infoURL),
               let info = try? decoder.decode(LibraryInfo.self, from: data),
               info.folderName == folderName {
                matches.append((dir, info))
            }
        }

        let preferredId = StableID.library(folderName: folderName)
        guard !matches.isEmpty else {
            let info = LibraryInfo(libraryId: preferredId, folderName: folderName)
            let dir = libraries.appendingPathComponent(info.libraryId, isDirectory: true)
            let store = try RecordStore(root: dir, info: info)
            let infoURL = dir.appendingPathComponent("library.json")
            // Another device may have made this same folder already, its file not listed yet.
            if Self.coordinatedRead(infoURL) == nil {
                try Self.coordinatedWrite(try RecordCoding.encoder().encode(info), to: infoURL)
            }
            try store.writeSchemaDoc(into: dataRoot)
            return store
        }

        matches.sort { a, b in
            let aPreferred = a.info.libraryId == preferredId, bPreferred = b.info.libraryId == preferredId
            if aPreferred != bPreferred { return aPreferred }
            return a.info.libraryId < b.info.libraryId
        }
        let store = try RecordStore(root: matches[0].dir, info: matches[0].info)
        for other in matches.dropFirst() where other.dir.standardizedFileURL != store.root.standardizedFileURL {
            try? store.absorb(libraryAt: other.dir)
        }
        return store
    }

    /// Copies every library kept under `source` (a data root, holding `Libraries/`) into
    /// `dataRoot`, merging with what is already there. Used to carry data kept on the device
    /// (builds without iCloud) into iCloud once iCloud is turned on. Safe to run more than once.
    public static func importLibraries(from source: URL, into dataRoot: URL) throws {
        let libraries = source.appendingPathComponent("Libraries", isDirectory: true)
        let dirs = (try? FileManager().contentsOfDirectory(at: libraries, includingPropertiesForKeys: nil)) ?? []
        let decoder = RecordCoding.decoder()
        for dir in dirs {
            guard let data = Self.coordinatedRead(dir.appendingPathComponent("library.json")),
                  let info = try? decoder.decode(LibraryInfo.self, from: data) else { continue }
            let store = try open(dataRoot: dataRoot, folderName: info.folderName)
            try store.absorb(libraryAt: dir)
        }
    }

    /// Merges another data folder's records and covers into this one, leaving it as it was.
    /// Throws if anything in it could not be read or written.
    func absorb(libraryAt other: URL) throws {
        let decoder = RecordCoding.decoder()
        var complete = true
        let books = other.appendingPathComponent("books", isDirectory: true)
        for url in Self.itemURLs(in: books) where url.pathExtension == "json" {
            guard let data = Self.coordinatedRead(url),
                  let record = try? decoder.decode(BookRecord.self, from: data) else { complete = false; continue }
            do { try write(record) } catch { complete = false }
        }
        let covers = other.appendingPathComponent("covers", isDirectory: true)
        for url in Self.itemURLs(in: covers) where url.pathExtension == "jpg" {
            let target = coversDirectory.appendingPathComponent(url.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) { continue }
            guard let data = Self.coordinatedRead(url) else { complete = false; continue }
            do { try Self.coordinatedWrite(data, to: target) } catch { complete = false }
        }
        if !complete { throw CocoaError(.fileReadUnknown) }
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
            // Nothing new: skip the write so iCloud has nothing to upload.
            if merged == existing { return existing }
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

    /// Every record, after folding together records that describe the same file under
    /// different ids. That happens when two devices first saw a book before iCloud synced. The
    /// id that stays is the one worked out from the path (`StableID`), else the lowest, so every
    /// device keeps the same one. Records whose file sizes disagree are left alone: one of them
    /// may be a path left behind by a move.
    public func consolidatedRecords() -> [BookRecord] {
        let records = allRecords()
        let groups = Dictionary(grouping: records) { $0.file.path.precomposedStringWithCanonicalMapping }
        var result: [BookRecord] = []
        for (path, group) in groups {
            guard group.count > 1 else { result += group; continue }
            let preferredId = StableID.book(path: path)
            let sorted = group.sorted { a, b in
                if (a.bookId == preferredId) != (b.bookId == preferredId) { return a.bookId == preferredId }
                return a.bookId < b.bookId
            }
            let keeper = sorted[0]
            var merged = keeper
            var folded: [BookRecord] = []
            for other in sorted.dropFirst() {
                if let a = keeper.file.size, let b = other.file.size, a != b {
                    result.append(other)
                    continue
                }
                merged = merged.merged(with: other)
                folded.append(other)
            }
            guard !folded.isEmpty, let written = try? write(merged) else {
                result += [keeper] + folded
                continue
            }
            for other in folded { removeRecord(other.bookId, keepCoverFor: keeper.bookId) }
            result.append(written)
        }
        return result
    }

    /// Deletes a folded-away record and its covers, moving a custom cover over if the kept
    /// record has none.
    private func removeRecord(_ bookId: String, keepCoverFor keeperId: String) {
        let custom = coverURL(bookId: bookId, custom: true)
        let keeperCustom = coverURL(bookId: keeperId, custom: true)
        if fileManager.fileExists(atPath: custom.path), !fileManager.fileExists(atPath: keeperCustom.path),
           let data = Self.coordinatedRead(custom) {
            try? Self.coordinatedWrite(data, to: keeperCustom)
        }
        for url in [recordURL(bookId: bookId), coverURL(bookId: bookId), custom] where fileManager.fileExists(atPath: url.path) {
            try? Self.coordinatedDelete(url)
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

    static func coordinatedDelete(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager().removeItem(at: url) } catch { deleteError = error }
        }
        if let error = coordinationError ?? deleteError { throw error }
    }

    /// Files in a folder, including ones still in iCloud only (listed as hidden `.name.icloud`
    /// placeholders), by their real names. A coordinated read downloads those.
    static func itemURLs(in directory: URL) -> [URL] {
        let urls = (try? FileManager().contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.map { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("."), url.pathExtension == "icloud" else { return url }
            let real = String(name.dropFirst().dropLast(".icloud".count))
            return directory.appendingPathComponent(real)
        }
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
