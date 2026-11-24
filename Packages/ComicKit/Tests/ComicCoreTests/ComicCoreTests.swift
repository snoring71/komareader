@testable import ComicCore
import Foundation
import Testing

@Suite struct ComicCoreTests {
    @Test func naturalSort() {
        let names = ["page10.jpg", "Page2.jpg", "page1.jpg", "ARIA 第02巻", "ARIA 第10巻", "ARIA 第01巻"]
        #expect(names.naturallySorted() == ["ARIA 第01巻", "ARIA 第02巻", "ARIA 第10巻", "page1.jpg", "Page2.jpg", "page10.jpg"])
    }

    /// Punctuation before digits before letters, as in Explorer, Finder and other readers.
    @Test func naturalSortPutsPunctuationFirst() {
        let pages = ["01.jpg", "a.jpg", "_02.jpg", "10.jpg", "_01.jpg", "2.jpg", "-cover.jpg", "０3.jpg"]
        #expect(pages.naturallySorted() == ["-cover.jpg", "_01.jpg", "_02.jpg", "01.jpg", "2.jpg", "０3.jpg", "10.jpg", "a.jpg"])
        #expect("_01.jpg".naturalLess(than: "01.jpg"))
        #expect(!"01.jpg".naturalLess(than: "_01.jpg"))
        #expect("Page 9".naturalLess(than: "page 10"))
        #expect("file99999999999999999999998".naturalLess(than: "file99999999999999999999999"))
        // Names that differ only in case or leading zeros still have one fixed order.
        #expect(["b", "001", "B", "1", "01"].naturallySorted() == ["001", "01", "1", "B", "b"])
    }

    /// Katakana and hiragana titles share one kana order, so each index letter is one run.
    @Test func naturalSortMixesKatakanaWithHiragana() {
        let titles = ["カードキャプター", "あずまんが", "かぐや様", "アキラ", "さくら", "ｱﾘｱ", "Zoo"]
        #expect(titles.naturallySorted() == ["Zoo", "アキラ", "あずまんが", "ｱﾘｱ", "かぐや様", "カードキャプター", "さくら"])
    }

    @Test func pageOrderGoesFolderByFolder() {
        let paths = ["a b/1.jpg", "a/2.jpg", "a/_1.jpg", "cover.jpg", "a/10.jpg", "ch10/1.jpg", "ch2/1.jpg"]
        #expect(PageOrder.sorted(paths) == ["a/_1.jpg", "a/2.jpg", "a/10.jpg", "a b/1.jpg", "ch2/1.jpg", "ch10/1.jpg", "cover.jpg"])
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

    @Test func splitPagesReadInOrder() {
        let wide: Set<Int> = [3]
        let ltr = SpreadLayout.displayPages(pageCount: 5, rightToLeft: false) { wide.contains($0) }
        #expect(ltr.map(\.description) == ["0", "1", "2", "3L", "3R", "4"])
        let rtl = SpreadLayout.displayPages(pageCount: 5, rightToLeft: true) { wide.contains($0) }
        #expect(rtl.map(\.description) == ["0", "1", "2", "3R", "3L", "4"])

        // One page per screen: every half is its own screen.
        #expect(SpreadLayout.spreads(ltr, twoPage: false) { wide.contains($0) }.count == 6)
        // Two pages: the halves of a split image stay together; page 2 stands alone before them.
        let two = SpreadLayout.spreads(ltr, twoPage: true) { wide.contains($0) }
        #expect(two.map { $0.map(\.description) } == [["0"], ["1", "2"], ["3L", "3R"], ["4"]])
        let shifted = SpreadLayout.spreads(SpreadLayout.displayPages(pageCount: 6, rightToLeft: false) { $0 == 2 }, twoPage: true) { $0 == 2 }
        #expect(shifted.map { $0.map(\.description) } == [["0"], ["1"], ["2L", "2R"], ["3", "4"], ["5"]])
        #expect(SpreadLayout.spreadIndex(containing: 3, in: two) == 2)
        #expect(SpreadLayout.spreadIndex(containing: 4, in: two) == 3)
    }

    @Test func pageSidesFollowTheTwoPageLayout() {
        // Pairs [1,2] [3,4], wide 5 alone, then [6,7]; the cover is a right page.
        let ltr = SpreadLayout.pageSides(pageCount: 8, rightToLeft: false) { $0 == 5 }
        #expect(ltr == [.right, .left, .right, .left, .right, .both, .left, .right])
        let rtl = SpreadLayout.pageSides(pageCount: 3, rightToLeft: true) { _ in false }
        #expect(rtl == [.left, .right, .left])
    }

    @Test func phaseThreeImageOptionsRoundTrip() throws {
        var options = BookRecord.ReaderOptions(updatedAt: Date(timeIntervalSince1970: 60))
        #expect(options.isEmpty)
        options.autoFix = true
        options.nightMode = .invert
        options.paperStock = .newsprint
        options.gamma = -0.3
        options.autoTrim = true
        #expect(!options.isEmpty)
        let data = try RecordCoding.encoder().encode(options)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"nightMode\" : \"invert\""))
        #expect(json.contains("\"paperStock\" : \"newsprint\""))
        #expect(!json.contains("descreen"))
        let decoded = try RecordCoding.decoder().decode(BookRecord.ReaderOptions.self, from: data)
        #expect(decoded == options)
        // A mode or paper from a newer version reads as off / plain instead of failing the record.
        let newer = json.replacingOccurrences(of: "\"invert\"", with: "\"neon\"")
            .replacingOccurrences(of: "\"newsprint\"", with: "\"vellum\"")
        let lenient = try RecordCoding.decoder().decode(BookRecord.ReaderOptions.self, from: Data(newer.utf8))
        #expect(lenient.nightMode == .off)
        #expect(lenient.paperStock == .plain)
        #expect(lenient.autoFix == true)
    }

    @Test func readerOptionsRoundTripAndFallBack() throws {
        var record = BookRecord(bookId: "R", file: .init(path: "r.cbz", size: 1, modified: nil))
        record.readerSettings = .init(direction: .rightToLeft, updatedAt: Date(timeIntervalSince1970: 40))
        #expect(record.effectiveReaderOptions.direction == .rightToLeft)
        #expect(record.effectiveReaderOptions.fit == nil)

        var options = BookRecord.ReaderOptions(updatedAt: Date(timeIntervalSince1970: 50))
        options.fit = .width
        options.background = .fromRGB(red: 1, green: 0.5, blue: 0)
        options.crop = .init(left: [0.06, 0.02, 0.9, 0.96], right: BookRecord.ReaderOptions.PageCrop.mirror([0.06, 0.02, 0.9, 0.96]), link: .mirrored)
        options.contrast = 0.25
        record.readerOptions = options
        // Once the book has its own options, they win (here: direction back to the default).
        #expect(record.effectiveReaderOptions.direction == nil)

        let data = try RecordCoding.encoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"background\" : \"#FF8000\""))
        #expect(!json.contains("portraitLayout"))
        #expect(json.contains("\"contrast\" : 0.25"))
        #expect(!json.contains("paperGrain"))
        let decoded = try RecordCoding.decoder().decode(BookRecord.self, from: data)
        #expect(decoded == record)
        let crop = try #require(decoded.readerOptions?.crop)
        #expect(crop.rect(for: .left) == [0.06, 0.02, 0.9, 0.96])
        #expect(abs(crop.rect(for: .right)[0] - 0.04) < 1e-9)
        // A whole spread keeps the outer margins trimmed and the middle intact.
        let spread = crop.rect(for: .both)
        #expect(abs(spread[0] - 0.03) < 1e-9 && abs(spread[0] + spread[2] - 0.97) < 1e-9)
        #expect(BookRecord.ReaderOptions.Background(code: "dynamic") == .dynamic)
        #expect(BookRecord.ReaderOptions.Background(code: "plaid") == .black)

        var newer = record
        newer.readerOptions?.fit = .height
        newer.readerOptions?.updatedAt = Date(timeIntervalSince1970: 60)
        #expect(record.merged(with: newer).readerOptions?.fit == .height)
    }

    @Test func recordStoreMergesWithDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecordStore.open(dataRoot: root, folderName: "Comics")
        var first = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        first.progress["ipad"] = .init(page: 1, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 10))
        try store.write(first)
        var second = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        second.progress["win"] = .init(page: 4, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 20))
        try store.write(second)

        let read = try #require(store.read(bookId: "B"))
        #expect(Set(read.progress.keys) == ["ipad", "win"])

        // Same folder name finds the same library.
        let reopened = try RecordStore.open(dataRoot: root, folderName: "Comics")
        #expect(reopened.info.libraryId == store.info.libraryId)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("SCHEMA.md").path))
    }

    /// `allRecords` keeps what it read in memory; a record changed on disk is read again.
    @Test func allRecordsSeesChangedRecords() throws {
        let store = try RecordStore.open(dataRoot: tempRoot(), folderName: "Comics")
        var record = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 1, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 10))
        try store.write(record)
        #expect(store.allRecords().first?.progress.keys.sorted() == ["ipad"])
        #expect(store.allRecords().first?.progress.keys.sorted() == ["ipad"])
        var other = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        other.progress["win"] = .init(page: 4, pageCount: 5, finished: false, updatedAt: Date(timeIntervalSince1970: 20))
        try store.write(other)
        #expect(store.allRecords().first?.progress.keys.sorted() == ["ipad", "win"])
        try store.write(BookRecord(bookId: "C", file: .init(path: "c.cbz", size: 1, modified: nil)))
        #expect(store.allRecords().map(\.bookId).sorted() == ["B", "C"])
    }

    @Test func stableIdsMatchTheDocumentedRecipe() {
        #expect(StableID.library(folderName: "Comics") == "20E7415A-EB37-81FE-87FB-C83F1AF87C00")
        #expect(StableID.book(path: "Saga/Saga 001.cbz") == "D0E63AF5-7548-8B27-8544-DCCDDEB4C6FA")
        // Decomposed and precomposed spellings of the same name give the same id.
        #expect(StableID.book(path: "Cafe\u{301}.cbz") == StableID.book(path: "Caf\u{E9}.cbz"))
        #expect(StableID.book(path: "a.cbz") != StableID.library(folderName: "a.cbz"))
    }

    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func devicesThatPickTheSameFolderShareALibraryId() throws {
        let a = try RecordStore.open(dataRoot: tempRoot(), folderName: "Comics")
        let b = try RecordStore.open(dataRoot: tempRoot(), folderName: "Comics")
        #expect(a.info.libraryId == b.info.libraryId)
        #expect(a.info.libraryId == StableID.library(folderName: "Comics"))
    }

    @Test func duplicateLibrariesAreFoldedTogether() throws {
        let root = tempRoot()
        // An older library made with a random id, as builds before stable ids did.
        let oldInfo = LibraryInfo(libraryId: "0-OLD", folderName: "Comics")
        let old = try RecordStore(root: root.appendingPathComponent("Libraries/0-OLD"), info: oldInfo)
        try RecordStore.coordinatedWrite(try RecordCoding.encoder().encode(oldInfo), to: old.root.appendingPathComponent("library.json"))
        var record = BookRecord(bookId: "B", file: .init(path: "b.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 3, pageCount: 9, finished: false)
        try old.write(record)
        try old.writeCover(Data([1]), bookId: "B")

        // A second library for the same folder, made by another device.
        let newInfo = LibraryInfo(libraryId: StableID.library(folderName: "Comics"), folderName: "Comics")
        let other = try RecordStore(root: root.appendingPathComponent("Libraries/\(newInfo.libraryId)"), info: newInfo)
        try RecordStore.coordinatedWrite(try RecordCoding.encoder().encode(newInfo), to: other.root.appendingPathComponent("library.json"))

        let store = try RecordStore.open(dataRoot: root, folderName: "Comics")
        #expect(store.info.libraryId == newInfo.libraryId)
        #expect(store.read(bookId: "B")?.progress["ipad"]?.page == 3)
        #expect(store.existingCoverURL(bookId: "B") != nil)
    }

    @Test func recordsForTheSameFileAreFoldedTogether() throws {
        let store = try RecordStore.open(dataRoot: tempRoot(), folderName: "Comics")
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

    @Test func epubIsSwitchedOff() {
        #expect(BookFormat.from(pathExtension: "epub") == .epub)
        #expect(BookFormat.enabled(pathExtension: "epub") == nil)
        #expect(BookFormat.enabled(pathExtension: "cbz") == .zip)
        #expect(!BookFormat.epub.isEnabled)
    }

    @Test func readsComicInfo() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Title>The Long Way</Title>
          <Series>Saga</Series>
          <Writer>Brian K. Vaughan</Writer>
          <Penciller>Fiona Staples</Penciller>
          <Publisher> Image Comics </Publisher>
          <Pages><Page Image="0" Type="FrontCover"/></Pages>
        </ComicInfo>
        """
        let info = try #require(BookData.comicInfo(Data(xml.utf8)))
        #expect(info.title == "The Long Way")
        #expect(info.series == "Saga")
        #expect(info.writers == ["Brian K. Vaughan"])
        #expect(info.authors == ["Brian K. Vaughan"])
        #expect(info.pencillers == ["Fiona Staples"])
        #expect(info.publisher == "Image Comics")

        // No writer: the penciller is the author. Empty fields count as missing.
        let art = try #require(BookData.comicInfo(Data("<ComicInfo><Writer></Writer><Penciller>Kozue Amano</Penciller></ComicInfo>".utf8)))
        #expect(art.authors == ["Kozue Amano"])
        #expect(art.title == nil && art.publisher == nil)

        #expect(BookData.comicInfo(Data("<html><Title>x</Title></html>".utf8)) == nil)
        #expect(BookData.comicInfo(Data("not xml".utf8)) == nil)
        #expect(BookData.isComicInfo(path: "Vol 1/comicinfo.XML"))
        #expect(!BookData.isComicInfo(path: "__MACOSX/Vol 1/ComicInfo.xml"))
    }

    @Test func readsEveryComicInfoField() throws {
        let xml = """
        <ComicInfo>
          <Title>Undine</Title><Series>ARIA</Series><Number>007</Number><Volume>7</Volume><Count>12</Count>
          <Summary>Akari's days in Neo-Venezia.</Summary>
          <Year>2005</Year><Month>4</Month><Day>10</Day>
          <Writer>天野こずえ</Writer><Penciller>天野こずえ</Penciller><Inker>A</Inker><Colorist>B, C</Colorist>
          <Letterer>D</Letterer><CoverArtist>E</CoverArtist><Editor>F</Editor><Translator>G</Translator>
          <Publisher>マッグガーデン</Publisher><Imprint>Blade Comics</Imprint>
          <Genre>Slice of Life, Sci-Fi</Genre><Tags>Venice; Gondola</Tags>
          <LanguageISO>ja</LanguageISO><AgeRating>Everyone</AgeRating><GTIN>9784861272000</GTIN>
          <Web>https://example.com/aria</Web><Manga>YesAndRightToLeft</Manga>
        </ComicInfo>
        """
        let info = try #require(BookData.comicInfo(Data(xml.utf8)))
        #expect(info.number == "7" && info.volume == "7" && info.count == 12)
        #expect(info.summary == "Akari's days in Neo-Venezia.")
        #expect(info.year == 2005 && info.month == 4 && info.day == 10)
        #expect(info.colorists == ["B", "C"])
        #expect(info.coverArtists == ["E"] && info.editors == ["F"] && info.translators == ["G"])
        #expect(info.imprint == "Blade Comics")
        #expect(info.genres == ["Slice of Life", "Sci-Fi"])
        #expect(info.tags == ["Venice", "Gondola"])
        #expect(info.language == "ja" && info.ageRating == "Everyone" && info.isbn == "9784861272000")
        #expect(info.web == "https://example.com/aria")
        #expect(info.rightToLeft == true)
        #expect(info.creators.first?.role == .writer)

        // ComicRack's "no volume" and "Unknown" rating are no value; plain manga is not right to left.
        let plain = try #require(BookData.comicInfo(Data("<ComicInfo><Volume>-1</Volume><AgeRating>Unknown</AgeRating><Manga>Yes</Manga></ComicInfo>".utf8)))
        #expect(plain.volume == nil && plain.ageRating == nil && plain.rightToLeft == nil)
    }

    @Test func editsWinOverTheFileAndTheFileOverTheName() {
        var name = BookData()
        name.series = "ARIA"
        name.number = "7"
        name.writers = ["From Name"]
        var file = BookData()
        file.series = "ARIA The Masterpiece"
        file.publisher = "Mag Garden"
        file.year = 2005
        file.month = 4
        var edit = BookData()
        edit.publisher = "  "
        edit.writers = []
        edit.year = 2010
        let merged = edit.overlaid(on: file.overlaid(on: name))
        #expect(merged.series == "ARIA The Masterpiece")
        #expect(merged.number == "7")
        #expect(merged.writers == ["From Name"])
        // Blank text and empty lists are no edit.
        #expect(merged.publisher == "Mag Garden")
        // A date is taken whole: the edit's year has no month.
        #expect(merged.year == 2010 && merged.month == nil)
    }

    @Test func metadataEditsRoundTripAndStayReadableByOlderVersions() throws {
        var values = BookData()
        values.series = "ARIA"
        values.pencillers = ["Kozue Amano"]
        values.genres = ["Sci-Fi"]
        values.summary = "Hi"
        let record = { () -> BookRecord in
            var r = BookRecord(bookId: "A", file: .init(path: "a.cbz", size: 1, modified: nil))
            r.metadata = .init(values, updatedAt: Date(timeIntervalSince1970: 1_000))
            return r
        }()
        let data = try RecordCoding.encoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        // Version 0.1 requires "writers".
        #expect(json.contains("\"writers\" : ["))
        let back = try RecordCoding.decoder().decode(BookRecord.self, from: data)
        #expect(back.metadata?.values == values)

        // A record written before the new fields existed still reads.
        let old = #"{"schema":1,"bookId":"B","file":{"path":"b.cbz"},"progress":{},"metadata":{"series":"S","writers":[],"updatedAt":"2026-01-01T00:00:00.000Z"}}"#
        let decoded = try RecordCoding.decoder().decode(BookRecord.self, from: Data(old.utf8))
        #expect(decoded.metadata?.values.series == "S")
        #expect(decoded.metadata?.values.writers == nil)
    }

    @Test func removedRecordsStayRemovedUntilUsedAgain() throws {
        var record = BookRecord(bookId: "R", file: .init(path: "r.cbz", size: 1, modified: nil))
        #expect(!record.isRemoved)
        record.removed = .init(updatedAt: Date(timeIntervalSince1970: 100))
        #expect(record.isRemoved)

        // An older copy with progress merged in (an iCloud conflict) does not bring it back.
        var old = BookRecord(bookId: "R", file: record.file)
        old.progress["ipad"] = .init(page: 3, pageCount: 10, finished: false, updatedAt: Date(timeIntervalSince1970: 50))
        old.flags = .init(favorite: true, updatedAt: Date(timeIntervalSince1970: 60))
        let merged = record.merged(with: old)
        #expect(merged.isRemoved)
        #expect(old.merged(with: record).isRemoved)

        // Reading it later does.
        var later = merged
        later.progress["win"] = .init(page: 1, pageCount: 10, finished: false, updatedAt: Date(timeIntervalSince1970: 200))
        #expect(!later.isRemoved)

        let decoded = try RecordCoding.decoder().decode(BookRecord.self, from: RecordCoding.encoder().encode(record))
        #expect(decoded == record)
    }

    @Test func markRemovedReplacesTheRecordAndDeletesCovers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecordStore.open(dataRoot: root, folderName: "Booklover")
        var record = BookRecord(bookId: "M", file: .init(path: "m.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 2, pageCount: 9, finished: false, updatedAt: Date())
        try store.write(record)
        try store.writeCover(Data([1, 2, 3]), bookId: "M")
        try store.writeCover(Data([1, 2, 3]), bookId: "M", custom: true)

        try store.markRemoved(bookId: "M", file: record.file)
        let read = try #require(store.read(bookId: "M"))
        #expect(read.isRemoved)
        #expect(read.progress.isEmpty)
        #expect(read.file.path == "m.cbz")
        #expect(store.existingCoverURL(bookId: "M") == nil)
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

    @Test func readsAuthorsVolumesYearsAndPublishersFromFileNames() {
        let aria = FileNameReader.read("[天野こずえ] ARIA 第07巻")
        #expect(aria.writers == ["天野こずえ"] && aria.series == "ARIA" && aria.number == "7")

        let general = FileNameReader.read("(一般コミック) [あずまきよひこ] よつばと! v01")
        #expect(general.writers == ["あずまきよひこ"] && general.series == "よつばと!" && general.number == "1")

        let pair = FileNameReader.read("[原作 太郎×作画 花子] タイトル 第3巻")
        #expect(pair.writers == ["原作 太郎", "作画 花子"])

        let complete = FileNameReader.read("ARIA 全12巻 第03巻")
        #expect(complete.count == 12 && complete.number == "3" && complete.series == "ARIA")

        let western = FileNameReader.read("Saga v03 (2019) (Image Comics)")
        #expect(western.year == 2019 && western.publisher == "Image Comics" && western.number == "3")

        // A release note after the year is not a publisher.
        let digital = FileNameReader.read("Saga 001 (2012) (Digital) (Zone-Empire)")
        #expect(digital.year == 2012 && digital.publisher == nil && digital.series == "Saga")

        // Full-width brackets count too.
        #expect(FileNameReader.read("［天野こずえ］ ARIA 第０２巻").writers == ["天野こずえ"])

        // A name that is only brackets keeps them as the series.
        #expect(FileNameReader.read("[Group] [Title]").writers == nil)
    }

    @Test func theFolderNamesTheSeriesWhenTheFileDoesNot() {
        let only = FileNameReader.read("第07巻", folder: "Manga/[天野こずえ] ARIA")
        #expect(only.series == "ARIA" && only.number == "7" && only.writers == ["天野こずえ"])
        #expect(FileNameReader.read("v02", folder: "Berserk").series == "Berserk")
        // "1984" is a title, not volume 1984 of the folder's series.
        #expect(FileNameReader.read("1984", folder: "Orwell").series == "1984")
    }

    @Test func rulesCanBeTurnedOffAndReordered() throws {
        var rules = FileNameRules.standard
        rules.rules = rules.rules.map { rule in
            var rule = rule
            if rule.kind == .leadingAuthor { rule.isOn = false }
            return rule
        }
        let off = FileNameReader.read("[天野こずえ] ARIA 第07巻", rules: rules)
        #expect(off.writers == nil && off.series == "ARIA")

        // The trailing number first: "Vol 2 03" is number 3, not 2.
        var trailingFirst = FileNameRules.standard
        let moved = trailingFirst.rules.remove(at: try #require(trailingFirst.rules.firstIndex { $0.kind == .trailingNumber }))
        trailingFirst.rules.insert(moved, at: 0)
        #expect(FileNameReader.read("Title Vol 2 03", rules: trailingFirst).number == "3")
        #expect(FileNameReader.read("Title Vol 2 03").number == "2")

        // Saved rules from an older version get any new kinds, switched on.
        let saved = #"{"rules":[{"kind":"westernVolume","isOn":false}]}"#
        let decoded = try JSONDecoder().decode(FileNameRules.self, from: Data(saved.utf8))
        #expect(decoded.rules.count == FileNameRules.Kind.allCases.count)
        #expect(decoded.rules.first?.kind == .westernVolume && !decoded.isOn(.westernVolume))
        #expect(decoded.isOn(.japaneseVolume))
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

@Suite struct TagListTests {
    @Test func tagsMergeOneByOneAndDeletesStick() throws {
        var a = TagList()
        a.add("Sci-Fi", at: Date(timeIntervalSince1970: 10))
        a.add("Old", at: Date(timeIntervalSince1970: 10))
        var b = a
        b.remove("old", at: Date(timeIntervalSince1970: 20))
        a.add("Manga", at: Date(timeIntervalSince1970: 30))
        let merged = a.merged(with: b)
        #expect(Set(merged.names) == ["Sci-Fi", "Manga"])
        #expect(Set(b.merged(with: a).names) == ["Sci-Fi", "Manga"])
        // An older copy cannot bring a deleted tag back, and keep() does not either.
        var c = merged
        c.keep("OLD")
        #expect(!c.contains("old"))
        c.add("Old", at: Date(timeIntervalSince1970: 40))
        #expect(c.contains("old"))
    }

    @Test func tagListIsSavedNextToTheRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try RecordStore(root: root, info: LibraryInfo(folderName: "Lib"))
        #expect(store.readTagList().names.isEmpty)
        try store.updateTagList { $0.add("Sci-Fi") }
        try store.updateTagList { $0.add("Empty") }
        #expect(Set(store.readTagList().names) == ["Sci-Fi", "Empty"])
    }

    // MARK: Progress reset (#52) and page bookmarks (#54)

    @Test func resetHidesOlderProgressFromEveryDevice() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var record = BookRecord(bookId: "b", file: .init(path: "b.cbz", size: 1, modified: nil))
        record.progress["ipad"] = .init(page: 5, pageCount: 20, finished: false, updatedAt: t0)
        record.progress["mac"] = .init(page: 9, pageCount: 20, finished: false, updatedAt: t0.addingTimeInterval(10))
        let older = record

        var reset = record
        reset.resetProgress(at: t0.addingTimeInterval(20))
        #expect(reset.progress.isEmpty)
        #expect(reset.latestProgress == nil)
        #expect(reset.wasReset(after: t0.addingTimeInterval(10)))
        #expect(!reset.wasReset(after: t0.addingTimeInterval(30)))

        // Another device's older copy still holds the old positions: they stay ignored.
        for merged in [reset.merged(with: older), older.merged(with: reset)] {
            #expect(merged.progressReset?.updatedAt == t0.addingTimeInterval(20))
            #expect(merged.latestProgress == nil)
            #expect(merged.progress.isEmpty)
            #expect(merged.handOff(for: "ipad", openingAt: 0) == nil)
        }

        // Reading again after the reset counts.
        var readAgain = reset
        readAgain.progress["mac"] = .init(page: 2, pageCount: 20, finished: false, updatedAt: t0.addingTimeInterval(30))
        let merged = readAgain.merged(with: older)
        #expect(merged.latestProgress?.progress.page == 2)
        #expect(!merged.wasReset(after: nil))
    }

    @Test func pageBookmarksSortAndMergeNewestWins() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(BookRecord.PageBookmarks(pages: [9, 2, 9, -1, 4], updatedAt: t0).pages == [2, 4, 9])
        var a = BookRecord(bookId: "b", file: .init(path: "b.cbz", size: 1, modified: nil))
        a.pageBookmarks = .init(pages: [1, 3], updatedAt: t0)
        var b = a
        b.pageBookmarks = .init(pages: [7], updatedAt: t0.addingTimeInterval(5))
        #expect(a.merged(with: b).pageBookmarks?.pages == [7])
        #expect(b.merged(with: a).pageBookmarks?.pages == [7])

        // Round trip through the file format; the whole-book mark is untouched.
        a.flags = .init(favorite: false, bookmarked: true, updatedAt: t0)
        a.resetProgress(at: t0)
        let data = try RecordCoding.encoder().encode(a)
        let decoded = try RecordCoding.decoder().decode(BookRecord.self, from: data)
        #expect(decoded == a)
        #expect(decoded.flags?.bookmarked == true)
    }
}

@Suite struct ListsAndRatingTests {
    @Test func listsMergePerListAndDeletionsStick() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var a = LibraryLists()
        a.put(.init(id: "L1", name: "Holiday", kind: .reading, bookIds: ["x"], position: 1), at: t0)
        a.put(.init(id: "L2", name: "Crossover", kind: .reading, bookIds: [], position: 2), at: t0)
        var b = a
        a.add(["y", "x"], to: "L1", at: t0.addingTimeInterval(10))
        b.delete("L2", at: t0.addingTimeInterval(5))
        let merged = a.merged(with: b)
        #expect(merged.list("L1")?.bookIds == ["x", "y"])
        #expect(merged.list("L2") == nil)
        #expect(merged.shown(.reading).map(\.id) == ["L1"])

        var moved = a
        moved.move("L2", by: -1, at: t0.addingTimeInterval(20))
        #expect(moved.shown(.reading).map(\.id) == ["L2", "L1"])

        let data = try RecordCoding.encoder().encode(merged)
        #expect(try RecordCoding.decoder().decode(LibraryLists.self, from: data) == merged)
    }

    @Test func ratingsMergeAndCountAsUse() {
        var record = BookRecord(bookId: "R", file: .init(path: "r.cbz", size: 1, modified: nil))
        record.removed = .init(updatedAt: Date(timeIntervalSince1970: 1_000))
        #expect(record.isRemoved)
        var rated = record
        rated.rating = .init(value: 4, updatedAt: Date(timeIntervalSince1970: 2_000))
        #expect(!rated.isRemoved)
        var cleared = record
        cleared.rating = .init(value: nil, updatedAt: Date(timeIntervalSince1970: 3_000))
        #expect(rated.merged(with: cleared).rating?.value == nil)
        #expect(BookRecord.Rating(value: 9).value == nil)
    }
}

@Suite struct TypedSearchTests {
    @Test func readsFieldPrefixesAndPlainWords() {
        let filter = LibraryFilter.parse(#"author:"Kozue Amano" year:2010-2015 rating:>=4 is:favorite status:unread tag:to-read aria"#)
        #expect(filter.text == "aria")
        #expect(filter.rules.map(\.field) == [.author, .year, .rating, .favorite, .status, .tag])
        #expect(filter.rules[0].values == ["Kozue Amano"])
        #expect(filter.rules[1].op == .between && filter.rules[1].values == ["2010", "2015"])
        #expect(filter.rules[2].op == .atLeast && filter.rules[2].values == ["4"])
        #expect(filter.rules[3].op == .isTrue)

        // ">3" is at least 4; an unknown prefix is a plain word.
        #expect(LibraryFilter.parse("rating:>3").rules.first?.values == ["4"])
        #expect(LibraryFilter.parse("re:zero").text == "re:zero")
        #expect(LibraryFilter.parse("is:cloud").rules.first?.op == .isFalse)
        #expect(LibraryFilter.parse("").isEmpty)
    }

    @Test func filtersRoundTrip() throws {
        let filter = LibraryFilter(match: .any, rules: [.init(.added, .inLast, ["30"])], text: "x")
        let data = try JSONEncoder().encode(filter)
        #expect(try JSONDecoder().decode(LibraryFilter.self, from: data) == filter)
    }
}
