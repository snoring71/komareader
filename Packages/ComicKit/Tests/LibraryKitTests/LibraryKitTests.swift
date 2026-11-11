import ArchiveKit
import ComicCore
import CoreGraphics
import Foundation
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
        let jpeg = try #require(ImageDecoder.jpegData(try #require(context.makeImage())))
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
}
