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
    var books: [Book] = []
    var thumbnails: [String: URL] = [:]
    var downloading: Set<String> = []
    var isScanning = false
    var errorMessage: String?
    var openBook: OpenBook?
    var selection: SidebarItem? = .all

    struct OpenBook: Identifiable {
        let book: Book
        let source: BookSource
        var id: String { book.id }
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

    // MARK: Startup

    func start() async {
        guard phase == .starting else { return }
        if Self.isDemo {
            let demo = await Task.detached { DemoLibrary.make() }.value
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
                let dataRoot = isDemo ? FileManager.default.temporaryDirectory.appendingPathComponent("DemoData") : LibraryLocation.appDataRoot().url
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
                Task { @MainActor in self?.thumbnails[id] = url }
            }
            self.covers = covers
            self.books = (try? index.allBooks()) ?? []
            self.phase = .ready
            watcher = FolderWatcher(url: url) { [weak self] in
                Task { @MainActor in self?.rescanSoon() }
            }
            await rescan()
        } catch {
            errorMessage = "Could not open the library: \(error.localizedDescription)"
            phase = .needsFolder
        }
    }

    // MARK: Scanning

    func rescanSoon() {
        guard phase == .ready else { return }
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await rescan()
        }
    }

    func rescan() async {
        guard let libraryURL, let store, let index else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                let scanned = LibraryScanner.scan(root: libraryURL)
                return try index.apply(scan: scanned, records: store.consolidatedRecords())
            }.value
            books = updated.sorted { $0.relativePath.naturalLess(than: $1.relativePath) }
            for book in books where thumbnails[book.id] == nil {
                if let thumb = covers?.existingThumbnail(bookId: book.id) { thumbnails[book.id] = thumb }
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

    func open(_ book: Book) async {
        guard let url = fileURL(for: book) else { return }
        if !book.isDownloaded || !CloudFiles.isDownloaded(url) {
            await download(book)
            guard CloudFiles.isDownloaded(url) else { return }
        }
        do {
            let cache = cacheRoot.appendingPathComponent("Pages", isDirectory: true)
            let source = try await BookSourceFactory.open(url: url, format: book.format, cacheDirectory: cache)
            let current = books.first { $0.id == book.id } ?? book
            openBook = OpenBook(book: current, source: source)
        } catch {
            errorMessage = "Could not open \(book.title): \(error.localizedDescription)"
        }
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
        updateBook(bookId) {
            $0.currentPage = page
            $0.pageCount = pageCount
            $0.finished = isFinished
            $0.lastReadAt = now
        }
        guard let store, let book = books.first(where: { $0.id == bookId }) else { return }
        let deviceId = deviceId
        progressTasks[bookId]?.cancel()
        progressTasks[bookId] = Task.detached(priority: .utility) {
            if !immediately {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
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

    private func updateBook(_ id: String, _ change: (inout Book) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        let book = books[i]
        try? index?.save(book)
    }
}
