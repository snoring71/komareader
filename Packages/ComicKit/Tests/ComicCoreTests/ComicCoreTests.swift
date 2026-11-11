@testable import ComicCore
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

    @Test func stableIdsMatchTheDocumentedRecipe() {
        #expect(StableID.library(folderName: "Booklover") == "352A9655-843C-82E4-BDCC-9A7C0DA6E14A")
        #expect(StableID.book(path: "Saga/Saga 001.cbz") == "D0E63AF5-7548-8B27-8544-DCCDDEB4C6FA")
        // Decomposed and precomposed spellings of the same name give the same id.
        #expect(StableID.book(path: "Cafe\u{301}.cbz") == StableID.book(path: "Caf\u{E9}.cbz"))
        #expect(StableID.book(path: "a.cbz") != StableID.library(folderName: "a.cbz"))
    }

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func devicesThatPickTheSameFolderShareALibraryId() throws {
        let a = try RecordStore.open(dataRoot: tempRoot(), folderName: "Booklover")
        let b = try RecordStore.open(dataRoot: tempRoot(), folderName: "Booklover")
        #expect(a.info.libraryId == b.info.libraryId)
        #expect(a.info.libraryId == StableID.library(folderName: "Booklover"))
    }

    @Test func duplicateLibrariesAreFoldedTogether() throws {
        let root = tempRoot()
        // An older library made with a random id, as builds before stable ids did.
        let oldInfo = LibraryInfo(libraryId: "0-OLD", folderName: "Booklover")
        let old = try RecordStore(root: root.appendingPathComponent("Libraries/0-OLD"), info: oldInfo)
        try RecordStore.coordinatedWrite(try RecordCoding.encoder().encode(oldInfo), to: old.root.appendingPathComponent("library.json"))
        var record = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 3, pageCount: 9, finished: false)
        try old.write(record)
        try old.writeCover(Data([1]), bookId: "B")

        // A second library for the same folder, made by another device.
        let newInfo = LibraryInfo(libraryId: StableID.library(folderName: "Booklover"), folderName: "Booklover")
        let other = try RecordStore(root: root.appendingPathComponent("Libraries/\(newInfo.libraryId)"), info: newInfo)
        try RecordStore.coordinatedWrite(try RecordCoding.encoder().encode(newInfo), to: other.root.appendingPathComponent("library.json"))

        let store = try RecordStore.open(dataRoot: root, folderName: "Booklover")
        #expect(store.info.libraryId == newInfo.libraryId)
        #expect(store.read(bookId: "B")?.progress["ipad"]?.page == 3)
        #expect(store.existingCoverURL(bookId: "B") != nil)
    }

    @Test func recordsForTheSameFileAreFoldedTogether() throws {
        let store = try RecordStore.open(dataRoot: tempRoot(), folderName: "Booklover")
        let path = "Saga/Saga 001.cbz"
        var mine = BookRecord(bookId: "ZZZ", file: .init(path: path, size: 10, modified: nil))
        mine.progress["ipad"] = .init(page: 4, pageCount: 20, finished: false)
        var theirs = BookRecord(bookId: StableID.book(path: path), file: .init(path: path, size: 10, modified: nil))
        theirs.progress["win"] = .init(page: 8, pageCount: 20, finished: false)
        // Same path but a different size: probably a different file, so it is left alone.
        let stale = BookRecord(bookId: "AAA", file: .init(path: path, size: 99, modified: nil))
        try store.write(mine)
        try store.write(theirs)
        try store.write(stale)
        try store.writeCover(Data([1]), bookId: "ZZZ", custom: true)

        let records = store.consolidatedRecords()
        #expect(Set(records.map(\.bookId)) == [theirs.bookId, "AAA"])
        let kept = try #require(store.read(bookId: theirs.bookId))
        #expect(Set(kept.progress.keys) == ["ipad", "win"])
        #expect(store.read(bookId: "ZZZ") == nil)
        #expect(FileManager.default.fileExists(atPath: store.coverURL(bookId: theirs.bookId, custom: true).path))
        #expect(Set(store.consolidatedRecords().map(\.bookId)) == [theirs.bookId, "AAA"])
    }

    @Test func localDataIsImportedIntoICloud() throws {
        let local = tempRoot(), cloud = tempRoot()
        let localStore = try RecordStore.open(dataRoot: local, folderName: "Books")
        var record = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 2, pageCount: 9, finished: false)
        try localStore.write(record)

        let cloudStore = try RecordStore.open(dataRoot: cloud, folderName: "Books")
        var synced = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        synced.progress["win"] = .init(page: 6, pageCount: 9, finished: false)
        try cloudStore.write(synced)

        try RecordStore.importLibraries(from: local, into: cloud)
        try RecordStore.importLibraries(from: local, into: cloud)
        let merged = try #require(cloudStore.read(bookId: "B"))
        #expect(Set(merged.progress.keys) == ["ipad", "win"])
    }
}

@Suite struct SeriesNameTests {
    @Test(arguments: [
        ("ARIA 第02巻", "ARIA", "2"),
        ("ARIA 第10巻", "ARIA", "10"),
        ("よつばと! 15巻", "よつばと!", "15"),
        ("Starfall 3", "Starfall", "3"),
        ("Saga 001 (2012) (Digital) [Empire]", "Saga", "1"),
        ("Saga - 054", "Saga", "54"),
        ("Berserk Vol. 41", "Berserk", "41"),
        ("Berserk v02", "Berserk", "2"),
        ("One_Piece_Volume_100", "One Piece", "100"),
        ("Batman #12", "Batman", "12"),
        ("20th Century Boys 03", "20th Century Boys", "3"),
        ("Chainsaw Man ch. 97.5", "Chainsaw Man", "97.5"),
        ("ＡＲＩＡ 第０２巻", "ARIA", "2"),
    ])
    func parsesSeriesAndNumber(title: String, series: String, number: String) {
        #expect(SeriesName.parse(title) == .init(series: series, number: number))
    }

    @Test func titlesWithoutANumberAreTheirOwnSeries() {
        #expect(SeriesName.parse("Maus") == .init(series: "Maus", number: nil))
        #expect(SeriesName.parse("1984") == .init(series: "1984", number: nil))
        #expect(SeriesName.parse("Akira (Colour) [Kodansha]") == .init(series: "Akira", number: nil))
    }
}

@Suite struct FlagsAndHandOffTests {
    @Test func flagsMergeByDateAndRoundTrip() throws {
        var a = BookRecord(bookId: "A", file: .init(path: "x.cbz", size: 1, modified: nil))
        var b = a
        a.flags = .init(favorite: true, bookmarked: false, updatedAt: Date(timeIntervalSince1970: 10))
        b.flags = .init(favorite: false, bookmarked: true, updatedAt: Date(timeIntervalSince1970: 20))
        #expect(a.merged(with: b).flags == b.flags)
        #expect(b.merged(with: a).flags == b.flags)
        let data = try RecordCoding.encoder().encode(a)
        #expect(String(decoding: data, as: UTF8.self).contains("\"favorite\" : true"))
        #expect(try RecordCoding.decoder().decode(BookRecord.self, from: data) == a)
    }

    @Test func handOffOffersTheFurthestPositionFromAnotherDevice() {
        var record = BookRecord(bookId: "A", file: .init(path: "x.cbz", size: 1, modified: nil))
        record.progress["ipad-1"] = .init(page: 13, pageCount: 20, finished: false, updatedAt: Date(timeIntervalSince1970: 10))
        // Only this device: nothing to offer.
        #expect(record.handOff(for: "ipad-1", openingAt: 3) == nil)

        record.progress["mac-2"] = .init(page: 9, pageCount: 20, finished: false, updatedAt: Date(timeIntervalSince1970: 5))
        record.progress["iphone-3"] = .init(page: 3, pageCount: 20, finished: false, updatedAt: Date(timeIntervalSince1970: 30))
        // Opening at the newest position (the iPhone's page 3), the Mac is further ahead.
        #expect(record.handOff(for: "ipad-1", openingAt: 3)?.device == "mac-2")
        #expect(record.handOff(for: "ipad-1", openingAt: 3)?.progress.page == 9)
        // Already at or past every other device: nothing to offer.
        #expect(record.handOff(for: "ipad-1", openingAt: 9) == nil)
        // Finished elsewhere does not count as ahead.
        record.progress["mac-2"]?.finished = true
        #expect(record.handOff(for: "ipad-1", openingAt: 3) == nil)
        #expect(DeviceIdentity.displayName(for: "mac-2") == "Mac")
        #expect(DeviceIdentity.displayName(for: "ipad-1a2b") == "iPad")
    }
}
