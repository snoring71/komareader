import ArchiveKit
import ComicCore
import Foundation
import LibraryKit
import Observation
import SwiftUI

/// App-wide state: the library folder, the indexed books, covers and the open book.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case starting, needsFolder, ready }

    var phase: Phase = .starting
    var libraryName = ""
    var books: [Book] = [] {
        didSet { booksDidChange(from: oldValue) }
    }
    /// Facts about the library that only change when books are added, removed, renamed or
    /// retitled (not on every page turn or download), worked out once instead of on every redraw.
    private(set) var catalog = Catalog()
    var thumbnails: [String: URL] = [:]
    var downloading: Set<String> = []
    var isScanning = false
    var errorMessage: String?
    var openBook: OpenBook? {
        didSet {
            let reading = openBook != nil
            guard reading != (oldValue != nil) else { return }
            // Making covers competes with decoding pages for the processor and the disk.
            Task { [covers] in await covers?.setPaused(reading) }
            if !reading { applyReadingProgress() }
        }
    }
    /// The open book with its latest position. It is kept out of `books` until the reader
    /// closes: changing `books` redraws the library behind the reader, and doing that on
    /// every page turn made page turns and the close button slow in a big library.
    @ObservationIgnored private var readingBook: Book?
    var selection: SidebarItem? = .all
    /// The book whose Book Info sheet is showing in the library.
    var bookInfo: BookRef?
    /// Bumped when a book's cover changes, so the grid reloads its thumbnail.
    var coverRevision: [String: Int] = [:]
    let coverPolicy = CoverPolicy()

    struct Catalog {
        /// Position of each book when sorted by title.
        var titleRank: [String: Int] = [:]
        /// The letter each book is filed under in the index.
        var indexKey: [String: String] = [:]
        var series: [SeriesGroup] = []
        var folders: [FolderNode] = []
    }

    private func booksDidChange(from old: [Book]) {
        let structural = old.count != books.count || zip(old, books).contains { a, b in
            a.id != b.id || a.title != b.title || a.series != b.series || a.number != b.number || a.isMissing != b.isMissing || a.relativePath != b.relativePath
        }
        guard structural else { return }
        var catalog = Catalog()
        struct Keyed {
            let title: NaturalSortKey
            let path: NaturalSortKey
            let book: Book
        }
        let keyed: [Keyed] = books.map { book in
            Keyed(title: NaturalSortKey(book.title), path: NaturalSortKey(book.relativePath), book: book)
        }
        let byTitle: [Book] = keyed.sorted { (a: Keyed, b: Keyed) -> Bool in
            if a.title == b.title { return a.path < b.path }
            return a.title < b.title
        }.map { (item: Keyed) -> Book in item.book }
        for (rank, book) in byTitle.enumerated() {
            catalog.titleRank[book.id] = rank
            catalog.indexKey[book.id] = IndexKey.of(book.title)
        }
        catalog.series = SeriesGroup.groups(from: books)
        catalog.folders = FolderNode.tree(from: books)
        self.catalog = catalog
    }

    struct OpenBook: Identifiable {
        let book: Book
        let source: BookSource
        /// A newer position from another device, offered when the reader opens.
        var handOff: HandOff?
        var id: String { book.id }
    }

    struct BookRef: Identifiable, Hashable { let id: String }

    struct HandOff: Equatable {
        let deviceName: String
        let page: Int
    }

    @ObservationIgnored private(set) var libraryURL: URL?
    @ObservationIgnored private var store: RecordStore?
    @ObservationIgnored private var index: LibraryIndex?
    @ObservationIgnored private var covers: CoverService?
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var progressTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored let deviceId = DeviceIdentity.current(platformPrefix: "ipad")

    static let isDemo = ProcessInfo.processInfo.arguments.contains("-demo")

    private var cacheRoot: URL { URL.cachesDirectory }
    /// Unpacked pages are stored by page number, so the folder is renamed whenever the page
    /// order rules change; folders from earlier versions are removed at launch.
    private static let pageCacheName = "Pages-2"
    private static let oldPageCacheNames = ["Pages"]

    // MARK: Startup

    func start() async {
        guard phase == .starting else { return }
        if Self.isDemo {
            let extra = UserDefaults.standard.integer(forKey: "demoCount")
            let demo = await Task.detached { DemoLibrary.make(extraBooks: extra) }.value
            await openLibrary(at: demo, saveBookmark: false)
        } else if let saved = LibraryLocation.restore() {
            await openLibrary(at: saved, saveBookmark: false)
        } else {
            phase = .needsFolder
        }
    }

    /// The user picked a folder in the system folder picker.
    func choose(folder url: URL) async {
        _ = url.startAccessingSecurityScopedResource()
        await openLibrary(at: url, saveBookmark: true)
    }

    /// Uses "iCloud Drive/Comic Reader/Books" when the user does not have a library folder yet.
    func useAppFolder() async {
        let root = await Task.detached { LibraryLocation.appDataRoot().url }.value
        let books = root.appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
        await openLibrary(at: books, saveBookmark: true)
    }

    func changeFolder() {
        watcher?.stop()
        LibraryLocation.clear()
        books = []
        thumbnails = [:]
        phase = .needsFolder
    }

    private func openLibrary(at url: URL, saveBookmark: Bool) async {
        do {
            if saveBookmark { try LibraryLocation.save(url) }
            let folderName = url.lastPathComponent
            let isDemo = Self.isDemo
            let (store, index) = try await Task.detached { () throws -> (RecordStore, LibraryIndex) in
                let dataRoot = isDemo ? DemoLibrary.dataRoot : LibraryLocation.appDataRoot().url
                let store = try RecordStore.open(dataRoot: dataRoot, folderName: folderName)
                let index = try LibraryIndex(url: URL.applicationSupportDirectory
                    .appendingPathComponent("Index", isDirectory: true)
                    .appendingPathComponent("\(store.info.libraryId).sqlite"))
                return (store, index)
            }.value
            self.libraryURL = url
            self.libraryName = folderName
            self.store = store
            self.index = index
            let covers = CoverService(store: store, thumbnailDirectory: cacheRoot.appendingPathComponent("Thumbnails/\(store.info.libraryId)", isDirectory: true))
            await covers.setHandler { [weak self] id, url in
                Task { @MainActor in
                    self?.thumbnails[id] = url
                    self?.coverRevision[id, default: 0] += 1
                }
            }
            await covers.setAllowsCloudDownloads(coverPolicy.allowsCloudDownloads)
            coverPolicy.onChange = { [weak covers] allowed in
                Task { await covers?.setAllowsCloudDownloads(allowed) }
            }
            self.covers = covers
            self.books = (try? index.allBooks()) ?? []
            self.phase = .ready
            let caches = cacheRoot, oldNames = Self.oldPageCacheNames
            Task.detached(priority: .utility) {
                for name in oldNames {
                    try? FileManager.default.removeItem(at: caches.appendingPathComponent(name, isDirectory: true))
                }
            }
            watcher = FolderWatcher(url: url) { [weak self] changed in
                Task { @MainActor in self?.folderChanged(at: changed) }
            }
            await rescan()
        } catch {
            errorMessage = "Could not open the library: \(error.localizedDescription)"
            phase = .needsFolder
        }
    }

    // MARK: Scanning

    /// A change reported inside the library folder. Changes to books we already know (their
    /// download state flipping while covers are made, for example) need no rescan; new or
    /// moved files and folders do.
    private func folderChanged(at url: URL?) {
        if let url, let libraryURL {
            let root = libraryURL.standardizedFileURL.path
            var path = url.standardizedFileURL.path
            if path.hasPrefix(root + "/") {
                path = String(path.dropFirst(root.count + 1))
                // Hidden ".Name.cbz.icloud" placeholders stand for "Name.cbz".
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    path = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(real)
                }
                let known = books.contains { !$0.isMissing && ($0.relativePath == path || path.hasPrefix($0.relativePath + "/")) }
                if known, FileManager.default.fileExists(atPath: url.path) || CloudFiles.isInCloud(url) { return }
            }
        }
        rescanSoon(delay: .seconds(2))
    }

    func rescanSoon(delay: Duration = .milliseconds(600)) {
        guard phase == .ready else { return }
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await rescan(showProgress: false)
        }
    }

    /// Rescans the library folder. `showProgress` shows the spinner (for a rescan the user asked for).
    func rescan(showProgress: Bool = true) async {
        guard let libraryURL, let store, let index else { return }
        if showProgress { isScanning = true }
        defer { if showProgress { isScanning = false } }
        let covers = covers
        let known = thumbnails
        do {
            let (updated, staleCovers, found) = try await Task.detached(priority: .userInitiated) { () throws -> ([Book], [String], [String: URL]) in
                let scanned = LibraryScanner.scan(root: libraryURL)
                let records = store.consolidatedRecords()
                // Covers edited on another device since this device made its thumbnail.
                let stale = records.compactMap { record -> String? in
                    guard let edited = record.cover?.updatedAt, let thumb = covers?.existingThumbnail(bookId: record.bookId),
                          let made = (try? thumb.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                          made < edited else { return nil }
                    return record.bookId
                }
                let books = try index.apply(scan: scanned, records: records)
                    .naturallySorted(by: \.relativePath)
                // Thumbnails already on disk, looked up here rather than on the main thread.
                var found: [String: URL] = [:]
                for book in books where known[book.id] == nil {
                    if let thumb = covers?.existingThumbnail(bookId: book.id) { found[book.id] = thumb }
                }
                return (books, stale, found)
            }.value
            // Assigning redraws everything that shows books, so only do it when something changed.
            if updated != books { books = updated }
            for id in staleCovers { await covers?.invalidate(bookId: id) }
            if !found.isEmpty || !staleCovers.isEmpty {
                // One assignment, made after the awaits above so covers finished meanwhile are kept.
                var thumbs = thumbnails
                thumbs.merge(found) { current, _ in current }
                for id in staleCovers { thumbs[id] = nil }
                thumbnails = thumbs
            }
            // Queue covers for everything else in the background; on-screen books go first.
            for book in books where thumbnails[book.id] == nil && !book.isMissing {
                requestCover(for: book, urgent: false)
            }
        } catch {
            errorMessage = "Could not scan the library: \(error.localizedDescription)"
        }
    }

    // MARK: Books

    func fileURL(for book: Book) -> URL? {
        libraryURL.map { book.relativePath.isEmpty ? $0 : $0.appendingPathComponent(book.relativePath) }
    }

    func requestCover(for book: Book, urgent: Bool) {
        guard thumbnails[book.id] == nil, let url = fileURL(for: book), let covers else { return }
        Task { await covers.request(book, fileURL: url, urgent: urgent) }
    }

    func download(_ book: Book) async {
        guard let url = fileURL(for: book) else { return }
        downloading.insert(book.id)
        defer { downloading.remove(book.id) }
        do {
            try await CloudFiles.download(url)
            updateBook(book.id) { $0.isDownloaded = true }
        } catch {
            errorMessage = "Could not download \(book.title): \(error.localizedDescription)"
        }
    }

    func removeDownload(_ book: Book) {
        guard let url = fileURL(for: book) else { return }
        do {
            try CloudFiles.evict(url)
            updateBook(book.id) { $0.isDownloaded = false }
        } catch {
            errorMessage = "Could not remove \(book.title) from this iPad: \(error.localizedDescription)"
        }
    }

    /// Opens a book's pages, downloading it first if it is only in iCloud.
    func source(for book: Book) async -> BookSource? {
        guard let url = fileURL(for: book) else { return nil }
        if !book.isDownloaded || !CloudFiles.isDownloaded(url) {
            await download(book)
            guard CloudFiles.isDownloaded(url) else { return nil }
        }
        do {
            let cache = cacheRoot.appendingPathComponent(Self.pageCacheName, isDirectory: true)
            return try await BookSourceFactory.open(url: url, format: book.format, cacheDirectory: cache)
        } catch {
            errorMessage = "Could not open \(book.title): \(error.localizedDescription)"
            return nil
        }
    }

    func open(_ book: Book) async {
        guard let source = await source(for: book) else { return }
        var current = books.first { $0.id == book.id } ?? book
        let record = await record(for: book.id)
        // The newest position wins on open, even if it arrived from another device since the last scan.
        if let latest = record?.latestProgress?.progress, latest.updatedAt > (current.lastReadAt ?? .distantPast) {
            updateBook(book.id) {
                $0.currentPage = latest.page
                $0.pageCount = latest.pageCount
                $0.finished = latest.finished
                $0.lastReadAt = latest.updatedAt
            }
            current = books.first { $0.id == book.id } ?? current
        }
        // Where the reader will start (see ReaderState), to compare with other devices.
        let start = min(max(0, current.finished ? 0 : (current.currentPage ?? 0)), max(0, source.pageCount - 1))
        var handOff: HandOff?
        if let other = record?.handOff(for: deviceId, openingAt: start), other.progress.page < source.pageCount {
            handOff = HandOff(deviceName: DeviceIdentity.displayName(for: other.device), page: other.progress.page)
        }
        bookInfo = nil
        openBook = OpenBook(book: current, source: source, handOff: handOff)
    }

    /// The book's synced record, read fresh from the data folder.
    func record(for bookId: String) async -> BookRecord? {
        guard let store else { return nil }
        return await Task.detached(priority: .userInitiated) { store.read(bookId: bookId) }.value
    }

    /// The book opened most recently, for the Resume button.
    var lastBook: Book? {
        books.filter { !$0.isMissing && $0.lastReadAt != nil }.max { ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast) }
    }

    /// Recently read books, newest first.
    func recentBooks(limit: Int) -> [Book] {
        Array(books.filter { !$0.isMissing && $0.lastReadAt != nil }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
            .prefix(limit))
    }

    func setFinished(_ book: Book, _ finished: Bool) {
        let pageCount = book.pageCount ?? 1
        saveProgress(bookId: book.id, page: finished ? max(0, pageCount - 1) : 0, pageCount: pageCount, finished: finished, immediately: true)
    }

    /// Called on every page turn. The index updates at once; the synced record is written
    /// after a short pause so fast page flipping does not hammer iCloud.
    func saveProgress(bookId: String, page: Int, pageCount: Int, finished: Bool? = nil, immediately: Bool = false) {
        let isFinished = finished ?? (page >= pageCount - 1)
        let now = Date()
        let change: (inout Book) -> Void = {
            $0.currentPage = page
            $0.pageCount = pageCount
            $0.finished = isFinished
            $0.lastReadAt = now
        }
        let whileReading = !immediately && openBook?.id == bookId
        if whileReading, var reading = readingBook ?? books.first(where: { $0.id == bookId }) {
            change(&reading)
            readingBook = reading
        } else {
            if readingBook?.id == bookId { readingBook = nil }
            updateBook(bookId, change)
        }
        guard let store, let book = (whileReading ? readingBook : nil) ?? books.first(where: { $0.id == bookId }) else { return }
        let deviceId = deviceId
        let index = whileReading ? index : nil
        progressTasks[bookId]?.cancel()
        progressTasks[bookId] = Task.detached(priority: .utility) {
            if !immediately {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            try? index?.save(book)
            var record = store.read(bookId: bookId) ?? BookRecord(bookId: bookId, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
            record.file = .init(path: book.relativePath, size: book.size, modified: book.modified, fingerprint: record.file.fingerprint)
            record.progress[deviceId] = .init(page: page, pageCount: pageCount, finished: isFinished, updatedAt: now)
            try? store.write(record)
        }
    }

    func saveDirection(bookId: String, rightToLeft: Bool) {
        updateBook(bookId) { $0.direction = rightToLeft ? "rtl" : "ltr" }
        guard let store, let book = books.first(where: { $0.id == bookId }) else { return }
        Task.detached(priority: .utility) {
            var record = store.read(bookId: bookId) ?? BookRecord(bookId: bookId, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
            var settings = record.readerSettings ?? .init()
            settings.direction = rightToLeft ? .rightToLeft : .leftToRight
            settings.updatedAt = Date()
            record.readerSettings = settings
            try? store.write(record)
        }
    }

    // MARK: Favorite and Bookmarked

    func setFavorite(_ book: Book, _ favorite: Bool) {
        setFlags(book) { $0.favorite = favorite }
    }

    func setBookmarked(_ book: Book, _ bookmarked: Bool) {
        setFlags(book) { $0.bookmarked = bookmarked }
    }

    private func setFlags(_ book: Book, _ change: @escaping @Sendable (inout BookRecord.Flags) -> Void) {
        var flags = BookRecord.Flags(favorite: book.favorite, bookmarked: book.bookmarked)
        change(&flags)
        let result = flags
        updateBook(book.id) {
            $0.favorite = result.favorite
            $0.bookmarked = result.bookmarked
        }
        updateRecord(book) { record in
            var flags = record.flags ?? .init(favorite: book.favorite, bookmarked: book.bookmarked)
            change(&flags)
            flags.updatedAt = Date()
            record.flags = flags
        }
    }

    // MARK: Covers

    /// Saves an edited cover: the recipe in the record and the rendered JPEG next to it, so other
    /// devices show it without the book. The rendered image is already rotated and cropped.
    func saveCover(_ book: Book, edit: BookRecord.CoverEdit, rendered: CGImage) async {
        guard let store else { return }
        if edit.isDefault {
            await resetCover(book)
            return
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                guard let full = ImageDecoder.jpegData(rendered, quality: 0.9) else { throw ArchiveError(message: "Could not encode the cover") }
                let scaled = try ImageDecoder.downsample(data: full, maxPixelSize: CoverService.sharedCoverHeight)
                guard let jpeg = ImageDecoder.jpegData(scaled, quality: 0.85) else { throw ArchiveError(message: "Could not encode the cover") }
                try store.writeCover(jpeg, bookId: book.id, custom: true)
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                record.cover = edit
                try store.write(record)
            }.value
            await refreshCover(book)
        } catch {
            errorMessage = "Could not save the cover: \(error.localizedDescription)"
        }
    }

    /// Goes back to the default cover (the first page).
    func resetCover(_ book: Book) async {
        guard let store else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.deleteCover(bookId: book.id, custom: true)
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                guard record.cover != nil else { return }
                // A default recipe, newer than the old edit, so other devices drop it too.
                record.cover = BookRecord.CoverEdit(page: 0)
                try store.write(record)
            }.value
            await refreshCover(book)
        } catch {
            errorMessage = "Could not reset the cover: \(error.localizedDescription)"
        }
    }

    /// The cover saved for a book (edited or default), for the Book Info sheet.
    func sharedCoverURL(for book: Book) -> URL? {
        store?.existingCoverURL(bookId: book.id)
    }

    private func refreshCover(_ book: Book) async {
        await covers?.invalidate(bookId: book.id)
        thumbnails[book.id] = nil
        coverRevision[book.id, default: 0] += 1
        requestCover(for: book, urgent: true)
    }

    /// Reads the record, applies `change`, and writes it back (merged with what is on disk).
    private func updateRecord(_ book: Book, _ change: @escaping @Sendable (inout BookRecord) -> Void) {
        guard let store else { return }
        Task.detached(priority: .utility) {
            var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
            change(&record)
            try? store.write(record)
        }
    }

    /// Puts the position reached in the reader into `books`, once, when the reader closes.
    private func applyReadingProgress() {
        guard let reading = readingBook else { return }
        readingBook = nil
        updateBook(reading.id) {
            $0.currentPage = reading.currentPage
            $0.pageCount = reading.pageCount
            $0.finished = reading.finished
            $0.lastReadAt = reading.lastReadAt
        }
    }

    private func updateBook(_ id: String, _ change: (inout Book) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        if readingBook?.id == id { change(&readingBook!) }
        let book = books[i]
        try? index?.save(book)
    }
}
