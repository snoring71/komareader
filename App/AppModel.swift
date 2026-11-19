import ArchiveKit
import ComicCore
import Foundation
import LibraryKit
import Observation
import SwiftUI
import UIKit

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
    /// Books waiting their turn to download: a download of many books fetches one at a time.
    var queuedDownloads: [String] = []
    @ObservationIgnored private var downloadQueueTask: Task<Void, Never>?
    var isScanning = false
    var errorMessage: String?
    var openBook: OpenBook? {
        didSet {
            let reading = openBook != nil
            guard reading != (oldValue != nil) else { return }
            // Making covers competes with decoding pages for the processor and the disk.
            Task { [covers] in await covers?.setPaused(reading) }
            if !reading {
                applyReadingProgress()
                flushFileMetadata()
            }
        }
    }
    /// The open book with its latest position. It is kept out of `books` until the reader
    /// closes: changing `books` redraws the library behind the reader, and doing that on
    /// every page turn made page turns and the close button slow in a big library.
    @ObservationIgnored private var readingBook: Book?
    /// A reading direction changed in the reader, put into `books` when the reader closes.
    @ObservationIgnored private var directionAfterReading: (id: String, direction: String?)?
    /// Page bookmarks changed in the reader, put into `books` when the reader closes.
    @ObservationIgnored private var bookmarksAfterReading: (id: String, pages: [Int])?
    var selection: SidebarItem? = .all {
        didSet {
            guard selection != oldValue else { return }
            // Each sidebar item starts at the top of its own stack.
            if !libraryPath.isEmpty { libraryPath = [] }
            restoreAnchor = nil
            LibraryPosition.save(selection: selection, path: libraryPath)
        }
    }
    /// Folders and series opened from the sidebar item, in order.
    var libraryPath: [SidebarItem] = [] {
        didSet { if libraryPath != oldValue { LibraryPosition.save(selection: selection, path: libraryPath) } }
    }
    /// The book to scroll back to when the library first appears after a launch.
    @ObservationIgnored private var restoreAnchor: LibraryPosition.Anchor?
    /// Counts for the sidebar and the tags in use, worked out when `books` changes rather
    /// than on every sidebar redraw.
    private(set) var summary = Summary()
    /// The library's synced tag list (`tags.json`), which keeps tags that have no books.
    @ObservationIgnored private var tagList = TagList()
    /// Folders and series pinned to the sidebar on this device, in the order they were pinned
    /// (#72). Saved as `SidebarItem.storageKey`s.
    var pinned: [SidebarItem] = AppModel.loadPinned() {
        didSet { UserDefaults.standard.set(pinned.map(\.storageKey), forKey: AppModel.pinnedKey) }
    }
    /// The book whose Book Info sheet is showing in the library.
    var bookInfo: BookRef?
    /// The books whose tags are being edited from the library: one from its long-press menu, or
    /// the selection in Select mode (#64).
    var tagEditor: TagEditorRequest?
    /// The book whose cover editor is showing, opened from the library's long-press menu.
    var coverEditor: CoverEditorRequest?
    /// True while the library shows something read from the files themselves (author,
    /// publisher, title), so books on this iPad have their metadata read in the background.
    var wantsFileMetadata = false {
        didSet { if wantsFileMetadata && !oldValue { readFileMetadata() } }
    }
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var pendingMetadata: [String: FileMetadata] = [:]
    @ObservationIgnored private var metadataFlushTask: Task<Void, Never>?
    /// Bumped when a book's cover changes, so the grid reloads its thumbnail.
    var coverRevision: [String: Int] = [:]
    let coverPolicy = CoverPolicy()
    let readerDefaults = ReaderDefaults()

    struct Catalog {
        /// Position of each book when sorted by title.
        var titleRank: [String: Int] = [:]
        /// The letter each book is filed under in the index.
        var indexKey: [String: String] = [:]
        var series: [SeriesGroup] = []
        /// Every folder that holds books, by path. The library folder itself is "".
        var folders: [String: FolderInfo] = [:]
        /// Where each book is in `books`.
        var position: [String: Int] = [:]
    }

    struct Summary: Equatable {
        var counts: [SidebarItem: Int] = [:]
        var tags: [TagCount] = []
    }

    struct TagCount: Hashable, Identifiable {
        let name: String
        let count: Int
        var id: String { name.lowercased() }
    }

    /// A book by id, without searching all of `books`.
    func book(id: String) -> Book? {
        guard let i = catalog.position[id], i < books.count, books[i].id == id else {
            return books.first { $0.id == id }
        }
        return books[i]
    }

    private func booksDidChange(from old: [Book]) {
        updateSummary()
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
        catalog.folders = FolderInfo.tree(from: books, titleRank: catalog.titleRank)
        for (i, book) in books.enumerated() { catalog.position[book.id] = i }
        self.catalog = catalog
    }

    /// One pass over the books. Assigned only when something changed, so the sidebar does
    /// not redraw on every change to `books`.
    private func updateSummary() {
        var counts: [SidebarItem: Int] = [:]
        var tagCounts: [String: (name: String, count: Int)] = [:]
        for book in books {
            if book.isMissing {
                counts[.missing, default: 0] += 1
                continue
            }
            counts[.all, default: 0] += 1
            if book.isDownloaded { counts[.downloaded, default: 0] += 1 }
            if book.favorite { counts[.favorites, default: 0] += 1 }
            if book.hasBookmarks { counts[.bookmarked, default: 0] += 1 }
            switch book.status {
            case .unread: counts[.unread, default: 0] += 1
            case .reading: counts[.reading, default: 0] += 1
            case .read: counts[.read, default: 0] += 1
            }
            for tag in book.tags {
                let key = tag.lowercased()
                tagCounts[key, default: (name: tag, count: 0)].count += 1
            }
        }
        counts[.continueReading] = counts[.reading]
        // Tags in the list with no books left are kept, with a count of 0.
        for name in tagList.names where tagCounts[name.lowercased()] == nil {
            tagCounts[name.lowercased()] = (name, 0)
        }
        let tags = tagCounts.values.map { TagCount(name: $0.name, count: $0.count) }.naturallySorted(by: \.name)
        let summary = Summary(counts: counts, tags: tags)
        if summary != self.summary { self.summary = summary }
    }

    struct OpenBook: Identifiable {
        let book: Book
        let source: BookSource
        /// A newer position from another device, offered when the reader opens.
        var handOff: HandOff?
        /// The book's own reader settings.
        var options: ReaderOptions
        /// The book's cover, shown first if Show Cover First is on, and from the page bar.
        var intro: CoverIntro?
        /// Bookmarked pages, from the synced record (newer than the library's copy).
        var bookmarks: [Int]?
        var id: String { book.id }
    }

    struct BookRef: Identifiable, Hashable { let id: String }

    struct TagEditorRequest: Identifiable {
        let ids: Set<String>
        let id = UUID()
    }

    /// One change from the tag editor, applied to every book it is editing.
    enum TagEdit {
        /// Adds the tag to every book that lacks it.
        case add(String)
        /// Takes the tag off every book.
        case remove(String)
        /// Takes every tag off the books ("No Tags"). The tags stay in the library's tag list.
        case clear
    }

    struct CoverEditorRequest: Identifiable {
        let book: Book
        let initialEdit: BookRecord.CoverEdit?
        var id: String { book.id }
    }

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
    private static let pageCacheName = "Pages-3"
    private static let oldPageCacheNames = ["Pages", "Pages-2"]

    // MARK: Startup

    func start() async {
        watchWindowsClosing()
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
            await covers.setMetadataHandler { [weak self] id, metadata in
                Task { @MainActor in self?.noteFileMetadata([id: metadata]) }
            }
            await covers.setAllowsCloudDownloads(coverPolicy.allowsCloudDownloads)
            coverPolicy.onChange = { [weak covers] allowed in
                Task { await covers?.setAllowsCloudDownloads(allowed) }
            }
            self.covers = covers
            // The cached book list and the covers already made, read in one go off the main
            // thread, so the library shows with its covers before the rescan finishes.
            let (cached, thumbs, tagList) = await Task.detached(priority: .userInitiated) {
                ((try? index.allBooks()) ?? [], covers.existingThumbnails(), store.readTagList())
            }.value
            self.tagList = tagList
            self.thumbnails = thumbs
            self.books = cached
            restorePosition()
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

    /// Reopens the sidebar item and the folders or series the user had open last time.
    private func restorePosition() {
        guard let saved = LibraryPosition.restore() else { return }
        guard exists(saved.selection) else { return }
        selection = saved.selection
        libraryPath = Array(saved.path.prefix { exists($0) })
        restoreAnchor = saved.anchor
    }

    /// Whether a saved sidebar item still has something to show.
    private func exists(_ item: SidebarItem) -> Bool {
        switch item {
        case .folder(let path): return catalog.folders[path] != nil
        case .seriesNamed(let name): return catalog.series.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        case .tag(let name): return summary.tags.contains { $0.id == name.lowercased() }
        case .missing: return summary.counts[.missing] != nil
        default: return true
        }
    }

    /// The book a grid should scroll to as it first appears, once.
    func takeRestoreAnchor(for list: String) -> String? {
        guard let anchor = restoreAnchor, anchor.list == list else { return nil }
        restoreAnchor = nil
        return anchor.bookId
    }

    // MARK: Folders

    func isPinned(_ item: SidebarItem) -> Bool { pinned.contains(item) }

    func setPinned(_ item: SidebarItem, _ isPinned: Bool) {
        if isPinned {
            if !pinned.contains(item) { pinned.append(item) }
        } else {
            pinned.removeAll { $0 == item }
        }
    }

    /// Whether a pinned item still has something to show: a folder or series can go away.
    func pinStillExists(_ item: SidebarItem) -> Bool { exists(item) }

    private static let pinnedKey = "pinnedItems"

    /// The pinned items, starting from the folders pinned before series could be (the old
    /// `pinnedFolders` list, kept as it was in case an older build runs again).
    private static func loadPinned() -> [SidebarItem] {
        let defaults = UserDefaults.standard
        if let keys = defaults.stringArray(forKey: pinnedKey) {
            return keys.compactMap(SidebarItem.init(storageKey:)).filter(\.isPinnable)
        }
        let folders = (defaults.stringArray(forKey: "pinnedFolders") ?? []).map(SidebarItem.folder)
        defaults.set(folders.map(\.storageKey), forKey: pinnedKey)
        return folders
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
            let (updated, staleCovers, found, tagList) = try await Task.detached(priority: .userInitiated) { () throws -> ([Book], [String], [String: URL], TagList) in
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
                return (books, stale, found, store.readTagList())
            }.value
            // Assigning redraws everything that shows books, so only do it when something changed.
            // Tags created, renamed or deleted on another device.
            if tagList != self.tagList {
                self.tagList = tagList
                updateSummary()
            }
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
            readFileMetadata()
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
        // A second tap while it downloads does not start it again.
        guard let url = fileURL(for: book), !downloading.contains(book.id) else { return }
        downloading.insert(book.id)
        defer { downloading.remove(book.id) }
        do {
            try await CloudFiles.download(url)
            updateBook(book.id) { $0.isDownloaded = true }
            if downloadQueueTask == nil { readFileMetadata() }
        } catch {
            errorMessage = "Could not download \(book.title): \(error.localizedDescription)"
        }
    }

    /// A tap on a book in the library. A book only in iCloud is downloaded and the library
    /// stays as it is; the next tap opens it. A tap while it downloads does nothing.
    func activate(_ book: Book) async {
        if downloading.contains(book.id) || queuedDownloads.contains(book.id) { return }
        if !book.isDownloaded {
            await download(book)
        } else {
            await open(book)
        }
    }

    /// Downloads several books, one after another.
    func download(_ ids: Set<String>) {
        let queued = Set(queuedDownloads)
        let wanted = books.filter { ids.contains($0.id) && !$0.isDownloaded && !$0.isMissing && !downloading.contains($0.id) && !queued.contains($0.id) }
        guard !wanted.isEmpty else { return }
        queuedDownloads += wanted.map(\.id)
        guard downloadQueueTask == nil else { return }
        downloadQueueTask = Task { [weak self] in
            while let self, !self.queuedDownloads.isEmpty {
                let next = self.queuedDownloads.removeFirst()
                if let book = self.books.first(where: { $0.id == next }), !book.isDownloaded {
                    await self.download(book)
                }
            }
            self?.downloadQueueTask = nil
            self?.readFileMetadata()
        }
    }

    /// Removes several books from this iPad (they stay in iCloud).
    func removeDownloads(_ ids: Set<String>) {
        queuedDownloads.removeAll { ids.contains($0) }
        let targets = books.filter { ids.contains($0.id) && $0.isDownloaded && !$0.isMissing }
            .compactMap { book in fileURL(for: book).map { (book.id, $0) } }
        guard !targets.isEmpty else { return }
        Task {
            let removed = await Task.detached(priority: .userInitiated) { () -> Set<String> in
                var removed: Set<String> = []
                for (id, url) in targets where CloudFiles.isInCloud(url) {
                    if (try? CloudFiles.evict(url)) != nil { removed.insert(id) }
                }
                return removed
            }.value
            updateBooks(removed) { $0.isDownloaded = false }
            if removed.count < targets.count {
                errorMessage = "Some books could not be removed from this iPad."
            }
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

    /// Opens a book's pages, downloading it first if it is only in iCloud. `quiet` (reopening
    /// the reader after iOS ended the app, #66) neither downloads nor shows an error.
    func source(for book: Book, quiet: Bool = false) async -> BookSource? {
        guard let url = fileURL(for: book) else { return nil }
        if !book.isDownloaded || !CloudFiles.isDownloaded(url) {
            if quiet { return nil }
            await download(book)
            guard CloudFiles.isDownloaded(url) else { return nil }
        }
        do {
            let cache = cacheRoot.appendingPathComponent(Self.pageCacheName, isDirectory: true)
            return try await BookSourceFactory.open(url: url, format: book.format, cacheDirectory: cache)
        } catch {
            if !quiet { errorMessage = "Could not open \(book.title): \(error.localizedDescription)" }
            return nil
        }
    }

    @ObservationIgnored private var sceneObserver: NSObjectProtocol?

    /// When the app's last window closes but the app keeps running, the reader closes (its
    /// page already saved) and the next window reopens it from `ReaderRestore`, like a relaunch.
    private func watchWindowsClosing() {
        guard sceneObserver == nil else { return }
        sceneObserver = NotificationCenter.default.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let left = UIApplication.shared.connectedScenes.count
                guard let self, left == 0, self.openBook != nil else { return }
                self.flushProgress()
                self.openBook = nil
            }
        }
    }

    /// Reopens the reader on the book that was open when iOS ended the app (#66). The page
    /// comes from the saved progress, as on any open. A book that is gone, missing or only in
    /// iCloud is skipped quietly, leaving the library.
    func restoreReader(bookId: String) async {
        guard !Self.isDemo, openBook == nil, let book = book(id: bookId), !book.isMissing, book.isDownloaded else { return }
        await open(book, restoring: true)
    }

    /// `restoring`: reopened after iOS ended the app, so no cover intro and no error messages.
    func open(_ book: Book, restoring: Bool = false) async {
        guard let source = await source(for: book, quiet: restoring) else { return }
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
        } else if let record, record.wasReset(after: current.lastReadAt), current.lastReadAt != nil || current.finished {
            // Reset on another device since the last scan: a first open again.
            updateBook(book.id) {
                $0.currentPage = nil
                $0.finished = false
                $0.lastReadAt = nil
            }
            current = books.first { $0.id == book.id } ?? current
        }
        // Where the reader will start, to compare with other devices.
        let start = ReaderState.startPage(for: current, pageCount: source.pageCount)
        var handOff: HandOff?
        if let other = record?.handOff(for: deviceId, openingAt: start), other.progress.page < source.pageCount {
            handOff = HandOff(deviceName: DeviceIdentity.displayName(for: other.device), page: other.progress.page)
        }
        bookInfo = nil
        var options = record?.effectiveReaderOptions ?? ReaderOptions(updatedAt: .distantPast)
        if record == nil, let direction = current.direction { options.direction = ReaderOptions.Direction(rawValue: direction) }
        let intro = restoring ? nil : await coverIntro(for: current)
        // Something else may have opened in the meantime.
        if restoring, openBook != nil { return }
        openBook = OpenBook(book: current, source: source, handOff: handOff, options: options, intro: intro,
                            bookmarks: record?.pageBookmarks?.pages)
    }

    /// Average cover colours, so a book opened again gets its background at once.
    private let coverColors = NSCache<NSString, UIColor>()

    /// The cover intro for a book, from its library thumbnail (already on disk, so it is quick).
    private func coverIntro(for book: Book) async -> CoverIntro? {
        guard let thumbnailURL = thumbnails[book.id] else { return nil }
        let key = "\(book.id)|\(coverRevision[book.id] ?? 0)" as NSString
        let knownColor = coverColors.object(forKey: key)
        let store = store, bookId = book.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> (image: UIImage, color: UIColor, fullSize: URL?)? in
            guard let data = try? Data(contentsOf: thumbnailURL), let decoded = UIImage(data: data) else { return nil }
            let image = decoded.preparingForDisplay() ?? decoded
            let color = knownColor ?? image.cgImage.flatMap { PageFilter.averageColor(of: $0) } ?? UIColor(white: 0.2, alpha: 1)
            return (image, color, store?.existingCoverURL(bookId: bookId))
        }.value
        guard let loaded else { return nil }
        coverColors.setObject(loaded.color, forKey: key)
        let firstOpen = book.lastReadAt == nil && (book.currentPage ?? 0) == 0 && !book.finished
        return CoverIntro(image: loaded.image, color: loaded.color, fullSizeURL: loaded.fullSize, waits: firstOpen)
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

    /// Marks several books as read, or resets them as unread (see `resetProgress`), with one
    /// change to `books`.
    func setFinished(_ ids: Set<String>, _ finished: Bool) {
        guard finished else {
            resetProgress(ids)
            return
        }
        let now = Date()
        let changed = updateBooks(ids) { book in
            let pageCount = book.pageCount ?? 1
            book.currentPage = finished ? max(0, pageCount - 1) : 0
            book.pageCount = pageCount
            book.finished = finished
            book.lastReadAt = now
        }
        let deviceId = deviceId
        updateRecords(changed) { record, book in
            record.file = .init(path: book.relativePath, size: book.size, modified: book.modified, fingerprint: record.file.fingerprint)
            record.progress[deviceId] = .init(page: book.currentPage ?? 0, pageCount: book.pageCount ?? 1, finished: finished, updatedAt: now)
        }
    }

    /// Sets the reading direction of several books.
    func setDirection(_ ids: Set<String>, _ direction: ReaderOptions.Direction) {
        let changed = updateBooks(ids) { $0.direction = direction.rawValue }
        let now = Date()
        updateRecords(changed) { record, _ in
            var options = record.effectiveReaderOptions
            options.direction = direction
            options.updatedAt = now
            record.readerOptions = options
            // Older versions only read `readerSettings`.
            record.readerSettings = .init(direction: direction, layout: .auto, updatedAt: now)
        }
    }

    /// Mark as Read, or Mark as Unread (which resets the book as if it had never been opened).
    func setFinished(_ book: Book, _ finished: Bool) {
        if finished {
            let pageCount = book.pageCount ?? 1
            saveProgress(bookId: book.id, page: max(0, pageCount - 1), pageCount: pageCount, finished: true, immediately: true)
        } else {
            resetProgress(book)
        }
    }

    /// Reading, from Book Info: a Read book goes back to Reading on the page it was on; an
    /// unread one counts as started on page 1.
    func markReading(_ book: Book) {
        guard book.status != .reading else { return }
        let pageCount = book.pageCount ?? 1
        let page = book.finished ? min(book.currentPage ?? 0, max(0, pageCount - 2)) : (book.currentPage ?? 0)
        saveProgress(bookId: book.id, page: page, pageCount: pageCount, finished: false, immediately: true, keepFinished: false)
    }

    /// Mark as Unread: resets reading progress as if the book had never been opened: no
    /// progress bar, status Unread, out of Continue Reading. This is the only way a book goes
    /// back to unread. Every device's position goes (see
    /// `BookRecord.progressReset`); the book's reader settings stay.
    func resetProgress(_ book: Book) {
        resetProgress([book.id])
    }

    /// Resets several books at once (Select mode), with one change to `books`.
    func resetProgress(_ ids: Set<String>) {
        for id in ids {
            progressTasks[id]?.cancel()
            progressTasks[id] = nil
            pendingProgress[id] = nil
        }
        if let reading = readingBook, ids.contains(reading.id) { readingBook = nil }
        let changed = updateBooks(ids) { book in
            book.currentPage = nil
            book.finished = false
            book.lastReadAt = nil
        }
        let now = Date()
        updateRecords(changed) { record, _ in record.resetProgress(at: now) }
    }

    /// Called on every page turn. The index updates at once; the synced record is written
    /// after a short pause so fast page flipping does not hammer iCloud. A finished book stays
    /// finished when its pages are turned back, unless `keepFinished` is false.
    func saveProgress(bookId: String, page: Int, pageCount: Int, finished: Bool? = nil, immediately: Bool = false, keepFinished: Bool = true) {
        let wasFinished = keepFinished && ((readingBook?.id == bookId ? readingBook : nil) ?? books.first { $0.id == bookId })?.finished == true
        let isFinished = (finished ?? (page >= pageCount - 1)) || wasFinished
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
            if let pending = bookmarksAfterReading, pending.id == bookId { reading.pageBookmarks = pending.pages }
            readingBook = reading
        } else {
            if readingBook?.id == bookId { readingBook = nil }
            updateBook(bookId, change)
        }
        guard let store, let book = (whileReading ? readingBook : nil) ?? books.first(where: { $0.id == bookId }) else { return }
        let deviceId = deviceId
        let index = whileReading ? index : nil
        let write: @Sendable () -> Void = {
            try? index?.save(book)
            var record = store.read(bookId: bookId) ?? BookRecord(bookId: bookId, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
            record.file = .init(path: book.relativePath, size: book.size, modified: book.modified, fingerprint: record.file.fingerprint)
            record.progress[deviceId] = .init(page: page, pageCount: pageCount, finished: isFinished, updatedAt: now)
            try? store.write(record)
        }
        progressTasks[bookId]?.cancel()
        let token = UUID()
        pendingProgress[bookId] = immediately ? nil : (token, write)
        progressTasks[bookId] = Task.detached(priority: .utility) { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            write()
            // Written: nothing left for flushProgress (unless a newer write took its place).
            await MainActor.run {
                if self?.pendingProgress[bookId]?.token == token { self?.pendingProgress[bookId] = nil }
            }
        }
    }

    /// Progress writes still waiting out `saveProgress`'s pause, so `flushProgress` can make them
    /// at once.
    @ObservationIgnored private var pendingProgress: [String: (token: UUID, write: @Sendable () -> Void)] = [:]

    /// Writes waiting progress now, when the app leaves the foreground, so the page is on disk
    /// before iOS can end the app (#66).
    func flushProgress() {
        guard !pendingProgress.isEmpty else { return }
        let writes = pendingProgress.values.map(\.write)
        for id in pendingProgress.keys { progressTasks[id]?.cancel() }
        pendingProgress = [:]
        for write in writes { write() }
    }

    /// Sets a book's reading direction from Book Info (the reader saves its settings itself).
    func saveDirection(bookId: String, rightToLeft: Bool) {
        let direction: ReaderOptions.Direction = rightToLeft ? .rightToLeft : .leftToRight
        updateBook(bookId) { $0.direction = direction.rawValue }
        Task {
            var options = await record(for: bookId)?.effectiveReaderOptions ?? ReaderOptions()
            options.direction = direction
            options.updatedAt = Date()
            saveReaderOptions(bookId: bookId, options: options)
        }
    }

    /// Clears a book's own reader settings (#53), so it follows Book Defaults again. Written
    /// as an empty settings group with a new date, so it syncs and wins over older settings on
    /// other devices. Progress, favorite, bookmark, tags, cover and metadata stay.
    func resetReaderOptions(bookId: String) {
        saveReaderOptions(bookId: bookId, options: ReaderOptions(updatedAt: Date()))
    }

    /// The direction a book reads in: its own, else the default for books.
    func direction(of book: Book) -> ReaderOptions.Direction {
        let own = directionAfterReading?.id == book.id ? directionAfterReading?.direction : book.direction
        return own.flatMap(ReaderOptions.Direction.init(rawValue:)) ?? readerDefaults.direction
    }

    /// Saves a book's own reader settings to its synced record.
    func saveReaderOptions(bookId: String, options: ReaderOptions) {
        let newDirection = options.direction?.rawValue
        if openBook?.id == bookId {
            // Changing `books` redraws the whole library behind the reader, which in a big
            // library held up the main thread long enough to drop taps in the reader's
            // settings. The library learns the direction when the reader closes.
            directionAfterReading = (bookId, newDirection)
        } else {
            updateBook(bookId) { $0.direction = newDirection }
        }
        guard let book = books.first(where: { $0.id == bookId }) else { return }
        // Older versions only read `readerSettings`, so keep its direction current too.
        let direction = options.direction ?? readerDefaults.direction
        updateRecord(book) { record in
            record.readerOptions = options
            record.readerSettings = .init(direction: direction, layout: .auto, updatedAt: options.updatedAt)
        }
    }

    // MARK: Favorite and Bookmarked

    /// Saves a book's bookmarked pages (from the reader) to its record and the index. The
    /// library's copy of the row catches up when the reader closes.
    func savePageBookmarks(bookId: String, pages: [Int]) {
        if openBook?.id == bookId {
            bookmarksAfterReading = (bookId, pages)
            if readingBook?.id == bookId { readingBook?.pageBookmarks = pages }
            try? index?.setPageBookmarks(pages, bookId: bookId)
        } else {
            updateBook(bookId) { $0.pageBookmarks = pages }
        }
        guard let book = books.first(where: { $0.id == bookId }) else { return }
        let now = Date()
        updateRecord(book) { record in record.pageBookmarks = .init(pages: pages, updatedAt: now) }
    }

    func setFavorite(_ book: Book, _ favorite: Bool) {
        setFlags(book) { $0.favorite = favorite }
    }

    func setBookmarked(_ book: Book, _ bookmarked: Bool) {
        setFlags(book) { $0.bookmarked = bookmarked }
    }

    func setFavorite(_ ids: Set<String>, _ favorite: Bool) {
        setFlags(ids) { $0.favorite = favorite }
    }

    func setBookmarked(_ ids: Set<String>, _ bookmarked: Bool) {
        setFlags(ids) { $0.bookmarked = bookmarked }
    }

    private func setFlags(_ ids: Set<String>, _ change: @escaping @Sendable (inout BookRecord.Flags) -> Void) {
        let changed = updateBooks(ids) { book in
            var flags = BookRecord.Flags(favorite: book.favorite, bookmarked: book.bookmarked)
            change(&flags)
            book.favorite = flags.favorite
            book.bookmarked = flags.bookmarked
        }
        let now = Date()
        updateRecords(changed) { record, book in
            var flags = record.flags ?? .init(favorite: book.favorite, bookmarked: book.bookmarked)
            change(&flags)
            flags.updatedAt = now
            record.flags = flags
        }
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

    // MARK: Tags

    /// Applies one tag editor change to many books in one batched update (one `books` change and
    /// one background record pass), never one `setTags` call per book. Tags a book loses stay in
    /// the library's tag list, as they do from the single-book editor.
    func editTags(_ ids: Set<String>, _ edit: TagEdit) {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        var changes: [String: [String]] = [:]
        var added: String?
        var lost: [String: String] = [:] // lowercased -> spelling, tags some book loses
        switch edit {
        case .add(let typed):
            let tag = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return }
            // An existing tag typed in another case is used as it is spelled already.
            let name = summary.tags.first { same($0.name, tag) }?.name
                ?? tagList.names.first { same($0, tag) } ?? tag
            added = name
            for id in ids {
                guard let book = book(id: id), !book.tags.contains(where: { same($0, name) }) else { continue }
                changes[id] = Self.cleaned(book.tags + [name])
            }
        case .remove(let tag):
            for id in ids {
                guard let book = book(id: id), let old = book.tags.first(where: { same($0, tag) }) else { continue }
                lost[old.lowercased()] = old
                changes[id] = book.tags.filter { !same($0, tag) }
            }
        case .clear:
            for id in ids {
                guard let book = book(id: id), !book.tags.isEmpty else { continue }
                for tag in book.tags { lost[tag.lowercased()] = tag }
                changes[id] = []
            }
        }
        let addToList = added.flatMap { tagList.contains($0) ? nil : $0 }
        let keep = lost.values.filter { tagList.tags[TagList.key($0)] == nil }
        if addToList != nil || !keep.isEmpty {
            changeTagList { list in
                let now = Date()
                for tag in keep { list.keep(tag, at: now) }
                if let addToList { list.add(addToList, at: now) }
            }
        }
        setTags(changes)
    }

    /// Renames a tag on every book that has it, or merges it into another tag of that name.
    func renameTag(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var changes: [String: [String]] = [:]
        for book in books where book.tags.contains(where: { $0.caseInsensitiveCompare(old) == .orderedSame }) {
            changes[book.id] = Self.cleaned(book.tags.map { $0.caseInsensitiveCompare(old) == .orderedSame ? name : $0 })
        }
        changeTagList { list in
            let now = Date()
            list.remove(old, at: now)
            list.add(name, at: now)
        }
        setTags(changes)
        if selection == .tag(old) { selection = .tag(name) }
    }

    /// Takes a tag off every book.
    func deleteTag(_ tag: String) {
        var changes: [String: [String]] = [:]
        for book in books where book.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            changes[book.id] = book.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
        }
        changeTagList { $0.remove(tag) }
        setTags(changes)
        if case .tag(let name) = selection, name.caseInsensitiveCompare(tag) == .orderedSame { selection = .all }
    }

    /// Changes the tag list here at once and in the synced `tags.json` in the background.
    private func changeTagList(_ change: @escaping @Sendable (inout TagList) -> Void) {
        change(&tagList)
        updateSummary()
        guard let store else { return }
        Task.detached(priority: .utility) { _ = try? store.updateTagList(change) }
    }

    /// Trims, drops empty tags and duplicates (ignoring case), keeping the first spelling.
    private static func cleaned(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    /// Applies new tags to many books in one change to `books`, one index transaction and one
    /// background pass over the records.
    private func setTags(_ changes: [String: [String]]) {
        guard !changes.isEmpty else { return }
        var updated = books
        var changed: [Book] = []
        for (id, tags) in changes {
            guard let i = catalog.position[id], i < updated.count, updated[i].id == id, updated[i].tags != tags else { continue }
            updated[i].tags = tags
            changed.append(updated[i])
        }
        guard !changed.isEmpty else { return }
        books = updated
        if var reading = readingBook, let tags = changes[reading.id] {
            reading.tags = tags
            readingBook = reading
        }
        let index = index, store = store, now = Date()
        Task.detached(priority: .utility) {
            try? index?.save(changed)
            guard let store else { return }
            for book in changed {
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                record.tags = .init(value: book.tags, updatedAt: now)
                try? store.write(record)
            }
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

    /// Throws away every cover this book has (an edit, the shared default cover, this device's
    /// thumbnail) and makes it again from the first page, as for a book just added. The record
    /// gets a fresh default recipe, so other devices see the newer date and rebuild theirs too.
    func regenerateCover(_ book: Book) async {
        guard let store else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.deleteCover(bookId: book.id, custom: true)
                try store.deleteCover(bookId: book.id, custom: false)
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                record.cover = BookRecord.CoverEdit(page: 0)
                try store.write(record)
            }.value
            await refreshCover(book)
        } catch {
            errorMessage = "Could not regenerate the cover: \(error.localizedDescription)"
        }
    }

    /// Regenerates the covers of several books (see `regenerateCover`).
    func regenerateCovers(_ ids: Set<String>) async {
        guard let store else { return }
        let targets = books.filter { ids.contains($0.id) && !$0.isMissing }
        guard !targets.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            let now = Date()
            for book in targets {
                try? store.deleteCover(bookId: book.id, custom: true)
                try? store.deleteCover(bookId: book.id, custom: false)
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                record.cover = BookRecord.CoverEdit(page: 0, updatedAt: now)
                try? store.write(record)
            }
        }.value
        for book in targets { await covers?.invalidate(bookId: book.id) }
        // One change each to the thumbnails and revisions, not one per book.
        var thumbs = thumbnails
        var revisions = coverRevision
        for book in targets {
            thumbs[book.id] = nil
            revisions[book.id, default: 0] += 1
        }
        thumbnails = thumbs
        coverRevision = revisions
        for book in targets { requestCover(for: book, urgent: false) }
    }

    /// Opens the cover editor from the library. The editor downloads a book that is only in
    /// iCloud while it shows its spinner.
    func editCover(_ book: Book) async {
        let edit = await record(for: book.id)?.cover
        coverEditor = CoverEditorRequest(book: book, initialEdit: edit)
    }

    // MARK: Deleting missing books

    /// Deletes missing books from the library: their index rows, thumbnails, shared covers and
    /// synced data. Their records are replaced by a note that they were removed, so other
    /// devices drop them too. Books whose files are still there are left alone.
    func deleteFromLibrary(_ ids: Set<String>) {
        let targets = books.filter { ids.contains($0.id) && $0.isMissing }
        guard !targets.isEmpty else { return }
        let targetIds = Set(targets.map(\.id))
        // One transaction now, so a rescan that starts next cannot bring the rows back.
        try? index?.delete(ids: Array(targetIds))
        books.removeAll { targetIds.contains($0.id) }
        var thumbs = thumbnails
        for id in targetIds { thumbs[id] = nil }
        thumbnails = thumbs
        let store = store, covers = covers
        Task.detached(priority: .utility) {
            let now = Date()
            for book in targets {
                await covers?.invalidate(bookId: book.id)
                try? store?.markRemoved(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified), at: now)
            }
        }
    }

    // MARK: File metadata

    /// Reads the metadata of books on this iPad that have not had it read yet, one book at a
    /// time in the background, while the library shows author, publisher or title. Never
    /// downloads anything; books in iCloud get theirs when a cover is made or they are downloaded.
    func readFileMetadata() {
        guard wantsFileMetadata, metadataTask == nil else { return }
        let todo = books.filter { !$0.isMissing && $0.isDownloaded && !$0.metadataRead }
            .compactMap { book in fileURL(for: book).map { (id: book.id, url: $0, format: book.format) } }
        guard !todo.isEmpty else { return }
        metadataTask = Task { [weak self] in
            for item in todo {
                // Stay out of the way of the reader, and stop if the overlay is turned off.
                while self?.openBook != nil, !Task.isCancelled { try? await Task.sleep(for: .seconds(2)) }
                guard let wanted = self?.wantsFileMetadata, wanted, !Task.isCancelled else { break }
                let metadata = await Task.detached(priority: .utility) { () -> FileMetadata? in
                    // A book removed from the iPad meanwhile is left for later.
                    guard CloudFiles.isDownloaded(item.url) else { return nil }
                    return MetadataReader.read(url: item.url, format: item.format) ?? FileMetadata()
                }.value
                if let metadata { self?.noteFileMetadata([item.id: metadata]) }
            }
            self?.metadataTask = nil
        }
    }

    /// Collects metadata as it is read and puts it into `books` every few seconds, since each
    /// change to `books` redraws the library.
    private func noteFileMetadata(_ items: [String: FileMetadata]) {
        pendingMetadata.merge(items) { _, new in new }
        guard metadataFlushTask == nil else { return }
        metadataFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.metadataFlushTask = nil
            self?.flushFileMetadata()
        }
    }

    private func flushFileMetadata() {
        // While a book is open the library waits; this runs again when the reader closes.
        guard openBook == nil, !pendingMetadata.isEmpty else { return }
        let items = pendingMetadata
        pendingMetadata = [:]
        let index = index
        Task.detached(priority: .utility) { try? index?.saveMetadata(items) }
        updateBooks(Set(items.keys), save: false) { book in
            guard let metadata = items[book.id] else { return }
            book.author = metadata.author
            book.publisher = metadata.publisher
            book.metadataTitle = metadata.title
            book.metadataRead = true
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
        if let pending = directionAfterReading {
            directionAfterReading = nil
            updateBook(pending.id) { $0.direction = pending.direction }
        }
        if let pending = bookmarksAfterReading {
            bookmarksAfterReading = nil
            updateBook(pending.id) { $0.pageBookmarks = pending.pages }
        }
        guard let reading = readingBook else { return }
        readingBook = nil
        updateBook(reading.id) {
            $0.currentPage = reading.currentPage
            $0.pageCount = reading.pageCount
            $0.finished = reading.finished
            $0.lastReadAt = reading.lastReadAt
        }
    }

    /// Changes several books with one assignment to `books` (each assignment redraws the
    /// library) and one index transaction. Returns the changed books.
    @discardableResult
    private func updateBooks(_ ids: Set<String>, save: Bool = true, _ change: (inout Book) -> Void) -> [Book] {
        guard !ids.isEmpty else { return [] }
        var all = books
        var changed: [Book] = []
        for i in all.indices where ids.contains(all[i].id) {
            change(&all[i])
            changed.append(all[i])
            if readingBook?.id == all[i].id { change(&readingBook!) }
        }
        guard !changed.isEmpty else { return [] }
        books = all
        if save {
            let index = index, saved = changed
            Task.detached(priority: .utility) { try? index?.save(saved) }
        }
        return changed
    }

    /// Reads each book's record, applies `change`, and writes it back, all in one background pass.
    private func updateRecords(_ books: [Book], _ change: @escaping @Sendable (inout BookRecord, Book) -> Void) {
        guard let store, !books.isEmpty else { return }
        Task.detached(priority: .utility) {
            for book in books {
                var record = store.read(bookId: book.id) ?? BookRecord(bookId: book.id, file: .init(path: book.relativePath, size: book.size, modified: book.modified))
                change(&record, book)
                try? store.write(record)
            }
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
