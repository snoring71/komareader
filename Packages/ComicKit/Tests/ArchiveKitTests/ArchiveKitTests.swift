import ArchiveKit
import Foundation
import Testing

@Suite struct ArchiveKitTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test(arguments: ["sample.cbz", "sample.cbt"])
    func readsPagesInNaturalOrder(name: String) async throws {
        let source = try ArchiveBookSource(url: try fixture(name), cacheRoot: try tempDir())
        #expect(source.pagePaths == ["Vol 1/page1.png", "Vol 1/page2.png", "Vol 1/page10.png"])
        #expect(source.pageCount == 3)

        let first = try await source.image(at: 0, maxPixelSize: 150)
        #expect(first.height == 150)
        #expect(first.width == 100)

        let wide = try await source.pageSize(at: 2)
        #expect(wide == CGSize(width: 400, height: 300))
    }

    @Test func reusesUnpackedPages() async throws {
        let cache = try tempDir()
        let url = try fixture("sample.cbz")
        _ = try await ArchiveBookSource(url: url, cacheRoot: cache).pageURL(at: 2)
        let again = try ArchiveBookSource(url: url, cacheRoot: cache)
        let page = try await again.pageURL(at: 2)
        #expect(FileManager.default.fileExists(atPath: page.path))
    }

    @Test func firstPageForCovers() async throws {
        let image = try await BookSourceFactory.firstPageImage(url: try fixture("sample.cbz"), format: .zip, maxPixelSize: 60)
        #expect(image.height == 60)
    }

    @Test func imageFolderIsABook() async throws {
        let dir = try tempDir()
        let pngData = try Data(contentsOf: try ArchiveBookSource(url: try fixture("sample.cbz"), cacheRoot: try tempDir()).pageURL(at: 0))
        for name in ["10.png", "2.png", "1.png"] { try pngData.write(to: dir.appendingPathComponent(name)) }
        let source = try FolderBookSource(url: dir)
        #expect(source.pageURLs.map(\.lastPathComponent) == ["1.png", "2.png", "10.png"])
    }

    @Test func badArchiveThrows() throws {
        let dir = try tempDir()
        let bad = dir.appendingPathComponent("bad.cbz")
        try Data("not an archive".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try ArchiveBookSource(url: bad, cacheRoot: dir) }
    }
}
