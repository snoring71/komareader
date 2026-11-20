import ArchiveKit
import ComicCore
import CoreGraphics
import Foundation
import GRDB
@testable import LibraryKit
import Testing

@Suite struct LibraryKitTests {
    func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("ARIA"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Scans/Issue 1"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("ARIA/ARIA 第10巻.cbr"))
        try Data([1, 2]).write(to: root.appendingPathComponent("ARIA/ARIA 第02巻.cbz"))
        try Data([1]).write(to: root.appendingPathComponent("Scans/Issue 1/001.jpg"))
        try Data([1]).write(to: root.appendingPathComponent("Scans/Issue 1/002.jpg"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        // A cloud-only placeholder in the old style.
        let plist = try PropertyListSerialization.data(fromPropertyList: ["NSURLFileSizeKey": 4096], format: .binary, options: 0)
        try plist.write(to: root.appendingPathComponent("ARIA/.ARIA 第03巻.cbz.icloud"))
        return root
    }

    @Test func scanFindsBooksFoldersAndPlaceholders() throws {
        let books = LibraryScanner.scan(root: try makeLibrary())
        #expect(books.map(\.relativePath) == ["ARIA/ARIA 第02巻.cbz", "ARIA/ARIA 第03巻.cbz", "ARIA/ARIA 第10巻.cbr", "Scans/Issue 1"])
        let placeholder = try #require(books.first { $0.title == "ARIA 第03巻" })
        #expect(!placeholder.isDownloaded)
        #expect(placeholder.size == 4096)
        #expect(placeholder.url.lastPathComponent == "ARIA 第03巻.cbz")
        #expect(books.last?.format == .folder)
        #expect(books.first?.folder == "ARIA")
    }

    @Test func indexKeepsIdsAcrossRescansAndMoves() throws {
        let index = try LibraryIndex()
        let book = ScannedBook(url: URL(fileURLWithPath: "/lib/a/Saga 1.cbz"), relativePath: "a/Saga 1.cbz", format: .zip, size: 99, modified: nil, isDownloaded: true)
        let first = try index.apply(scan: [book], records: [])
        let id = try #require(first.first?.id)

        // Rescan: same id.
        #expect(try index.apply(scan: [book], records: []).first?.id == id)

        // Gone: kept but marked missing.
        let gone = try index.apply(scan: [], records: [])
        #expect(gone.first?.isMissing == true)

        // Reappears elsewhere with the same name and size: treated as a move.
        var moved = book
        moved.relativePath = "b/Saga 1.cbz"
        let after = try index.apply(scan: [moved], records: [])
        #expect(after.count == 1)
        #expect(after.first?.id == id)
        #expect(after.first?.relativePath == "b/Saga 1.cbz")
    }

    @Test func indexStoresTagsFromRecords() throws {
        let index = try LibraryIndex()
        let book = ScannedBook(url: URL(fileURLWithPath: "/lib/Saga 1.cbz"), relativePath: "Saga 1.cbz", format: .zip, size: 9, modified: nil, isDownloaded: true)
        var first = try #require(try index.apply(scan: [book], records: []).first)
        #expect(first.tags.isEmpty)

        var record = BookRecord(bookId: first.id, file: .init(path: "Saga 1.cbz", size: 9, modified: nil))
        record.tags = .init(value: ["Sci-Fi", "To Read"])
        let tagged = try #require(try index.apply(scan: [book], records: [record]).first)
        #expect(tagged.tags == ["Sci-Fi", "To Read"])
        #expect(try index.book(id: first.id)?.tags == ["Sci-Fi", "To Read"])

        first.tags = ["Space"]
        try index.save(first)
        #expect(try index.allBooks().first?.tags == ["Space"])
    }

    @Test func indexAdoptsIdsAndProgressFromSyncedRecords() throws {
        let index = try LibraryIndex()
        var record = BookRecord(bookId: "FROM-IPAD", file: .init(path: "x.cbz", size: 5, modified: nil))
        record.progress["other"] = .init(page: 7, pageCount: 20, finished: false, updatedAt: Date())
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/x.cbz"), relativePath: "x.cbz", format: .zip, size: 5, modified: nil, isDownloaded: false)
        let books = try index.apply(scan: [scanned], records: [record])
        #expect(books.first?.id == "FROM-IPAD")
        #expect(books.first?.currentPage == 7)
        #expect(books.first?.status == .reading)
    }

    @Test func newBooksGetTheIdOtherDevicesWorkOut() throws {
        let index = try LibraryIndex()
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/x.cbz"), relativePath: "x.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        #expect(try index.apply(scan: [scanned], records: []).first?.id == StableID.book(path: "x.cbz"))
    }

    @Test func indexSwitchesToASyncedIdThatArrivesLater() throws {
        let index = try LibraryIndex()
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/x.cbz"), relativePath: "x.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        let localId = try #require(try index.apply(scan: [scanned], records: []).first?.id)

        // Another device's record for the same file, under an id it made before stable ids.
        var record = BookRecord(bookId: "FROM-WINDOWS", file: .init(path: "x.cbz", size: 5, modified: nil))
        record.progress["win"] = .init(page: 3, pageCount: 10, finished: false, updatedAt: Date())
        let books = try index.apply(scan: [scanned], records: [record])
        #expect(books.map(\.id) == ["FROM-WINDOWS"])
        #expect(books.first?.currentPage == 3)
        #expect(try index.book(id: localId) == nil)

        // Stays put on the next scan.
        #expect(try index.apply(scan: [scanned], records: [record]).map(\.id) == ["FROM-WINDOWS"])
    }

    @Test func indexWorksOutSeriesAndCopiesFlags() throws {
        let index = try LibraryIndex()
        let aria = ScannedBook(url: URL(fileURLWithPath: "/lib/ARIA 第02巻.cbz"), relativePath: "ARIA 第02巻.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        let other = ScannedBook(url: URL(fileURLWithPath: "/lib/x 3.cbz"), relativePath: "x 3.cbz", format: .zip, size: 6, modified: nil, isDownloaded: true)
        var record = BookRecord(bookId: StableID.book(path: "x 3.cbz"), file: .init(path: "x 3.cbz", size: 6, modified: nil))
        record.flags = .init(favorite: true, bookmarked: true)
        record.metadata = .init(series: "Real Name", number: "3")
        let books = try index.apply(scan: [aria, other], records: [record])
        let first = try #require(books.first { $0.relativePath == aria.relativePath })
        #expect(first.series == "ARIA")
        #expect(first.number == "2")
        #expect(!first.favorite)
        let second = try #require(books.first { $0.relativePath == other.relativePath })
        #expect(second.series == "Real Name")
        #expect(second.favorite && second.bookmarked)
    }

    /// A folder book with one small page, on the device.
    func makeFolderBook(in root: URL, name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let image = try #require(context.makeImage())
        let jpeg = try #require(ImageDecoder.jpegData(image))
        try jpeg.write(to: folder.appendingPathComponent("001.jpg"))
        return folder
    }

    func waitFor(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func coverJobsForICloudBooksWaitUntilAllowed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try RecordStore.open(dataRoot: root.appendingPathComponent("Data"), folderName: "Lib")
        let covers = CoverService(store: store, thumbnailDirectory: root.appendingPathComponent("Thumbs"), cloudPause: 0)
        let local = try makeFolderBook(in: root, name: "Local 1")
        let cloud = try makeFolderBook(in: root, name: "Cloud 1")
        func book(_ id: String, _ downloaded: Bool) -> Book {
            Book(id: id, relativePath: id, title: id, folder: "", format: .folder, size: nil, modified: nil,
                 isDownloaded: downloaded, isMissing: false, addedAt: Date(), pageCount: nil, currentPage: nil,
                 finished: false, lastReadAt: nil, direction: nil, favorite: false, bookmarked: false, series: id, number: nil)
        }
        await covers.setAllowsCloudDownloads(false)
        await covers.request(book("L", true), fileURL: local, urgent: false)
        await covers.request(book("C", false), fileURL: cloud, urgent: false)
        #expect(await waitFor { covers.existingThumbnail(bookId: "L") != nil })
        #expect(await covers.waitingForCloud == 1)
        #expect(covers.existingThumbnail(bookId: "C") == nil)

        await covers.setAllowsCloudDownloads(true)
        #expect(await waitFor { covers.existingThumbnail(bookId: "C") != nil })
        #expect(await covers.waitingForCloud == 0)
        #expect(store.existingCoverURL(bookId: "C") != nil)
    }

    @Test func newCoversLoseTheirPlainSideMargins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try RecordStore.open(dataRoot: root.appendingPathComponent("Data"), folderName: "Lib")
        let covers = CoverService(store: store, thumbnailDirectory: root.appendingPathComponent("Thumbs"), cloudPause: 0)
        let folder = root.appendingPathComponent("Margins 1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 200 × 300, white bands of 20 px on each side.
        let context = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 160, height: 300))
        let jpeg = try #require(ImageDecoder.jpegData(try #require(context.makeImage()), quality: 1))
        try jpeg.write(to: folder.appendingPathComponent("001.jpg"))
        let book = Book(id: "M", relativePath: "M", title: "M", folder: "", format: .folder, size: nil, modified: nil,
                        isDownloaded: true, isMissing: false, addedAt: Date(), pageCount: nil, currentPage: nil,
                        finished: false, lastReadAt: nil, direction: nil, favorite: false, bookmarked: false, series: "M", number: nil)
        await covers.request(book, fileURL: folder, urgent: true)
        #expect(await waitFor { covers.existingThumbnail(bookId: "M") != nil })
        let edit = try #require(store.read(bookId: "M")?.cover)
        #expect(edit.page == 0 && edit.rotation == 0)
        #expect(abs(edit.crop[0] - 0.105) < 0.02)
        #expect(abs(edit.crop[2] - 0.79) < 0.03)
        #expect(FileManager.default.fileExists(atPath: store.coverURL(bookId: "M", custom: true).path))
        #expect(FileManager.default.fileExists(atPath: store.coverURL(bookId: "M").path))
    }

    @Test func scanLeavesOutEpubs() throws {
        let root = try makeLibrary()
        try Data([1]).write(to: root.appendingPathComponent("ARIA/Novel.epub"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["NSURLFileSizeKey": 10], format: .binary, options: 0)
        try plist.write(to: root.appendingPathComponent("ARIA/.Other.epub.icloud"))
        let books = LibraryScanner.scan(root: root)
        #expect(!books.contains { $0.format == .epub })
        #expect(books.count == 4)
    }

    @Test func indexDropsEpubsInsteadOfMarkingThemMissing() throws {
        let index = try LibraryIndex()
        let comic = ScannedBook(url: URL(fileURLWithPath: "/lib/a.cbz"), relativePath: "a.cbz", format: .zip, size: 1, modified: nil, isDownloaded: true)
        let epub = ScannedBook(url: URL(fileURLWithPath: "/lib/b.epub"), relativePath: "b.epub", format: .epub, size: 2, modified: nil, isDownloaded: true)
        // As an older version indexed it.
        try index.apply(scan: [comic, epub], records: [])
        #expect(try index.allBooks().map(\.relativePath) == ["a.cbz"])

        // This version's scan no longer lists it: the row goes, it is not shown as missing.
        let books = try index.apply(scan: [comic], records: [])
        #expect(books.map(\.relativePath) == ["a.cbz"])
        #expect(!books.contains { $0.isMissing })
    }

    @Test func indexDropsMissingBooksRemovedOnAnyDevice() throws {
        let index = try LibraryIndex()
        let a = ScannedBook(url: URL(fileURLWithPath: "/lib/a.cbz"), relativePath: "a.cbz", format: .zip, size: 1, modified: nil, isDownloaded: true)
        let b = ScannedBook(url: URL(fileURLWithPath: "/lib/b.cbz"), relativePath: "b.cbz", format: .zip, size: 2, modified: nil, isDownloaded: true)
        let ids = try index.apply(scan: [a, b], records: []).map(\.id)
        #expect(try index.apply(scan: [], records: []).allSatisfy(\.isMissing))

        // Deleted here.
        try index.delete(ids: [ids[0]])
        // Deleted on another device: its record says so.
        var record = BookRecord(bookId: ids[1], file: .init(path: "b.cbz", size: 2, modified: nil))
        record.removed = .init()
        #expect(try index.apply(scan: [], records: [record]).isEmpty)

        // The file comes back: a fresh book.
        let back = try index.apply(scan: [b], records: [record])
        #expect(back.count == 1)
        #expect(back.first?.isMissing == false)
        #expect(back.first?.currentPage == nil)
    }

    @Test func indexOpensAfterAnyBranchsV3() throws {
        // A device that ran another build's "v3" (tags only) still gets the metadata columns.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        do {
            let queue = try DatabaseQueue(path: url.path)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1") { db in
                try db.create(table: "book") { t in
                    t.primaryKey("id", .text)
                    t.column("relativePath", .text).notNull()
                    t.column("title", .text).notNull()
                    t.column("folder", .text).notNull()
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
            migrator.registerMigration("v3") { db in
                try db.alter(table: "book") { t in t.add(column: "tags", .text).notNull().defaults(to: "[]") }
            }
            try migrator.migrate(queue)
        }
        let index = try LibraryIndex(url: url)
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/a.cbz"), relativePath: "a.cbz", format: .zip, size: 1, modified: nil, isDownloaded: true)
        let id = try #require(try index.apply(scan: [scanned], records: []).first?.id)
        try index.saveMetadata([id: FileMetadata(author: "W")])
        #expect(try index.book(id: id)?.author == "W")
        let columns = try index.db.read { db in try db.columns(in: "book").map(\.name) }
        #expect(columns.contains("tags"))
    }

    @Test func indexKeepsFileMetadataUntilTheFileChanges() throws {
        let index = try LibraryIndex()
        var book = ScannedBook(url: URL(fileURLWithPath: "/lib/a.cbz"), relativePath: "a.cbz", format: .zip, size: 1, modified: Date(timeIntervalSince1970: 1_000.123456), isDownloaded: true)
        let id = try #require(try index.apply(scan: [book], records: []).first?.id)
        #expect(try index.book(id: id)?.metadataRead == false)

        try index.saveMetadata([id: FileMetadata(title: "T", author: "W", publisher: "P")])
        let saved = try #require(try index.apply(scan: [book], records: []).first)
        #expect(saved.metadataRead)
        #expect(saved.author == "W" && saved.publisher == "P" && saved.metadataTitle == "T")

        book.modified = Date(timeIntervalSince1970: 5_000)
        #expect(try index.apply(scan: [book], records: []).first?.metadataRead == false)
    }

    @Test func indexShowsResetBooksAsNeverOpened() throws {
        let index = try LibraryIndex()
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/r.cbz"), relativePath: "r.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        var record = BookRecord(bookId: StableID.book(path: "r.cbz"), file: .init(path: "r.cbz", size: 5, modified: nil))
        let t0 = Date(timeIntervalSince1970: 1_000)
        record.progress["other"] = .init(page: 19, pageCount: 20, finished: true, updatedAt: t0)
        let read = try #require(try index.apply(scan: [scanned], records: [record]).first)
        #expect(read.status == .read)

        // Marked unread on another device; its older entry comes back in a merge.
        var reset = record
        reset.resetProgress(at: t0.addingTimeInterval(5))
        let merged = reset.merged(with: record)
        let book = try #require(try index.apply(scan: [scanned], records: [merged]).first)
        #expect(book.status == .unread)
        #expect(book.progressFraction == nil)
        #expect(book.lastReadAt == nil)
        // And it stays that way on the next scan.
        #expect(try index.apply(scan: [scanned], records: [merged]).first?.status == .unread)
    }

    @Test func indexStoresPageBookmarks() throws {
        let index = try LibraryIndex()
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/p.cbz"), relativePath: "p.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        let first = try #require(try index.apply(scan: [scanned], records: []).first)
        #expect(first.pageBookmarks.isEmpty)
        #expect(!first.hasBookmarks)

        try index.setPageBookmarks([4, 11], bookId: first.id)
        let stored = try #require(try index.book(id: first.id))
        #expect(stored.pageBookmarks == [4, 11])
        #expect(stored.hasBookmarks)

        var record = BookRecord(bookId: first.id, file: .init(path: "p.cbz", size: 5, modified: nil))
        record.pageBookmarks = .init(pages: [2])
        #expect(try index.apply(scan: [scanned], records: [record]).first?.pageBookmarks == [2])
    }

    /// A database that already ran every other branch's updates (v3, v4, tags) still opens
    /// and gets the page bookmarks column.
    @Test func pageBookmarksMigrationRunsAfterOtherBranches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        do {
            let first = try LibraryIndex(url: url)
            try first.db.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'page-bookmarks-54'")
            }
        }
        // Reopening runs the migration again over a table that already has the column.
        let index = try LibraryIndex(url: url)
        let scanned = ScannedBook(url: URL(fileURLWithPath: "/lib/m.cbz"), relativePath: "m.cbz", format: .zip, size: 5, modified: nil, isDownloaded: true)
        #expect(try index.apply(scan: [scanned], records: []).count == 1)
    }
}
