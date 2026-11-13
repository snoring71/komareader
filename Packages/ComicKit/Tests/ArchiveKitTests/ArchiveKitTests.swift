import ArchiveKit
import CoreGraphics
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
        let firstPage = try await ArchiveBookSource(url: try fixture("sample.cbz"), cacheRoot: try tempDir()).pageURL(at: 0)
        let pngData = try Data(contentsOf: firstPage)
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

@Suite struct CoverRendererTests {
    /// A 4×2 image: left half red, right half blue.
    func halves() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        return try #require(context.makeImage())
    }

    /// Red and blue of the pixel at (x, y), counted from the top left.
    func color(_ image: CGImage, _ x: Int, _ y: Int) throws -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - (image.height - 1), width: image.width, height: image.height))
        return (pixel[0], pixel[2])
    }

    @Test func rotatesClockwiseThenCrops() throws {
        let image = try halves()
        let turned = try #require(CoverRenderer.rotate(image, degrees: 90))
        #expect(turned.width == 2 && turned.height == 4)
        // Clockwise: the left (red) half ends up on top.
        #expect(try color(turned, 0, 0).red > 200)
        #expect(try color(turned, 0, 3).blue > 200)
        let upsideDown = try #require(CoverRenderer.rotate(image, degrees: 180))
        #expect(try color(upsideDown, 0, 0).blue > 200)
        let anticlockwise = try #require(CoverRenderer.rotate(image, degrees: 270))
        #expect(try color(anticlockwise, 0, 0).blue > 200)

        let top = try #require(CoverRenderer.render(image, crop: [0, 0, 1, 0.5], rotation: 90))
        #expect(top.width == 2 && top.height == 2)
        #expect(try color(top, 1, 1).red > 200)
        let right = try #require(CoverRenderer.render(image, crop: [0.5, 0, 0.5, 1], rotation: 0))
        #expect(right.width == 2 && right.height == 2)
        #expect(try color(right, 0, 0).blue > 200)
    }
}
