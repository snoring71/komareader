import ComicCore
import Foundation
import Testing

@Suite struct ComicCoreTests {
    @Test func naturalSort() {
        let names = ["page10.jpg", "Page2.jpg", "page1.jpg", "ARIA 第02巻", "ARIA 第10巻", "ARIA 第01巻"]
        #expect(names.naturallySorted() == ["ARIA 第01巻", "ARIA 第02巻", "ARIA 第10巻", "page1.jpg", "Page2.jpg", "page10.jpg"])
    }

    @Test func pageFilter() {
        #expect(PageFilter.isPage(path: "Vol 1/001.JPG"))
        #expect(PageFilter.isPage(path: "a.webp"))
        #expect(!PageFilter.isPage(path: "ComicInfo.xml"))
        #expect(!PageFilter.isPage(path: "__MACOSX/._001.jpg"))
        #expect(!PageFilter.isPage(path: ".DS_Store"))
    }

    @Test func formats() {
        #expect(BookFormat.from(pathExtension: "CBR") == .rar)
        #expect(BookFormat.from(pathExtension: "cb7") == .sevenZip)
        #expect(BookFormat.from(pathExtension: "txt") == nil)
    }

    @Test func recordRoundTripsThroughJSON() throws {
        var record = BookRecord(bookId: "A", file: .init(path: "Saga/Saga 001.cbz", size: 10, modified: Date(timeIntervalSince1970: 1_700_000_000.25)))
        record.tags = .init(value: ["sci-fi"], updatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        record.progress["ipad"] = .init(page: 3, pageCount: 20, finished: false, updatedAt: Date(timeIntervalSince1970: 1_700_000_002.5))
        let data = try RecordCoding.encoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"path\" : \"Saga/Saga 001.cbz\""))
        #expect(json.contains("2023-11-14T22:13:20.250Z"))
        #expect(!json.contains("metadata"))
        let decoded = try RecordCoding.decoder().decode(BookRecord.self, from: data)
        #expect(decoded == record)
    }

    @Test func mergeKeepsNewestPerGroupAndPerDevice() {
        let t0 = Date(timeIntervalSince1970: 0), t1 = Date(timeIntervalSince1970: 100), t2 = Date(timeIntervalSince1970: 200)
        var a = BookRecord(bookId: "A", file: .init(path: "x.cbz", size: 1, modified: nil))
        var b = a
        a.tags = .init(value: ["old"], updatedAt: t0)
        b.tags = .init(value: ["new"], updatedAt: t1)
        a.metadata = .init(series: "Mine", updatedAt: t2)
        b.metadata = .init(series: "Theirs", updatedAt: t1)
        a.progress["ipad"] = .init(page: 5, pageCount: 10, finished: false, updatedAt: t1)
        b.progress["ipad"] = .init(page: 2, pageCount: 10, finished: false, updatedAt: t0)
        b.progress["win"] = .init(page: 9, pageCount: 10, finished: false, updatedAt: t2)

        let merged = a.merged(with: b)
        #expect(merged.tags?.value == ["new"])
        #expect(merged.metadata?.series == "Mine")
        #expect(merged.progress["ipad"]?.page == 5)
        #expect(merged.progress["win"]?.page == 9)
        #expect(merged.latestProgress?.device == "win")
        #expect(b.merged(with: a) == merged)
    }

    @Test func spreads() {
        let wide: Set<Int> = [5]
        let layout = SpreadLayout.spreads(pageCount: 9, twoPage: true) { wide.contains($0) }
        #expect(layout == [[0], [1, 2], [3, 4], [5], [6, 7], [8]])
        #expect(SpreadLayout.spreads(pageCount: 3, twoPage: false) { _ in false } == [[0], [1], [2]])
        #expect(SpreadLayout.spreadIndex(containing: 7, in: layout) == 4)
    }

    @Test func recordStoreMergesWithDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecordStore.open(dataRoot: root, folderName: "Booklover")
        var first = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        first.progress["ipad"] = .init(page: 1, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 10))
        try store.write(first)
        var second = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        second.progress["win"] = .init(page: 4, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 20))
        try store.write(second)

        let read = try #require(store.read(bookId: "B"))
        #expect(Set(read.progress.keys) == ["ipad", "win"])

        // Same folder name finds the same library.
        let reopened = try RecordStore.open(dataRoot: root, folderName: "Booklover")
        #expect(reopened.info.libraryId == store.info.libraryId)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("SCHEMA.md").path))
    }
}
