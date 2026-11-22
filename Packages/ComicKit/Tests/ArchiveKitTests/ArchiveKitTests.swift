import ArchiveKit
import ComicCore
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

    /// A white page of 200 × 300 with a dark block covering x 20..<180, y 30..<270.
    func pageWithMargins() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        // Core Graphics counts y from the bottom: 30 from the top is 30 from the bottom here too.
        context.fill(CGRect(x: 20, y: 30, width: 160, height: 240))
        return try #require(context.makeImage())
    }

    @Test func findsMarginsAndEdgeColour() throws {
        let page = try pageWithMargins()
        let bounds = ImageAnalysis.contentBounds(of: page)
        #expect(abs(bounds[0] - 0.1) < 0.02)
        #expect(abs(bounds[1] - 0.1) < 0.02)
        #expect(abs(bounds[2] - 0.8) < 0.03)
        #expect(abs(bounds[3] - 0.8) < 0.03)
        let edge = try #require(ImageAnalysis.edgeColor(of: page))
        #expect(edge.red > 0.95 && edge.green > 0.95 && edge.blue > 0.95)
    }

    /// A cover of 300 × 400: `band` colour down the left `left` and right `right` pixels,
    /// colourful art in between, and an optional dark watermark in the left band.
    func cover(left: Int, right: Int, band: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
               watermark: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(band)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: left, y: 0, width: 300 - left - right, height: 400))
        if watermark {
            // A small vertical logo in the band: 10% of the height.
            context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 5, y: 180, width: max(1, left - 10), height: 40))
        }
        return try #require(context.makeImage())
    }

    @Test func trimsPlainSideMarginsFromCovers() throws {
        let crop = try #require(ImageAnalysis.marginCrop(of: try cover(left: 30, right: 15)))
        // 30 px, then one more in; 15 px, then one more in; top and bottom untouched.
        #expect(abs(crop[0] - 31.0 / 300) < 0.001)
        #expect(abs(crop[2] - 253.0 / 300) < 0.001)
        #expect(crop[1] == 0 && crop[3] == 1)
    }

    @Test func trimsBlackMarginsWithAWatermark() throws {
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let crop = try #require(ImageAnalysis.marginCrop(of: try cover(left: 30, right: 0, band: black, watermark: true)))
        #expect(abs(crop[0] - 31.0 / 300) < 0.001)
        #expect(abs(crop[2] - 269.0 / 300) < 0.001)
    }

    @Test func leavesColouredAndThinBordersAlone() throws {
        let blue = CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        #expect(ImageAnalysis.marginCrop(of: try cover(left: 30, right: 30, band: blue)) == nil)
        #expect(ImageAnalysis.marginCrop(of: try cover(left: 0, right: 0)) == nil)
        // Mostly blank: trimming would leave less than a fifth, so the sides stay.
        let blank = ImageAnalysis.marginCrop(of: try cover(left: 130, right: 130))
        #expect(blank == nil || (blank?[0] == 0 && blank?[2] == 1))
    }

    /// A 300 × 400 white page; `draw` adds to it (Core Graphics counts y from the bottom).
    func page(_ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 300, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test func trimsStackedBands() throws {
        // Grey frame 20 px each side; art from 20 to 140; white from 140 to the grey frame.
        let image = try page { context in
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 400))
            context.fill(CGRect(x: 280, y: 0, width: 20, height: 400))
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 20, y: 0, width: 120, height: 400))
        }
        let crop = try #require(ImageAnalysis.marginCrop(of: image))
        #expect(abs(crop[0] - 21.0 / 300) < 0.001)
        #expect(abs(crop[2] - 118.0 / 300) < 0.001)
    }

    @Test func artRunningAcrossABandIsNotAMargin() throws {
        // White on the left 30 px, but a red title strip runs from the edge into the art.
        let image = try page { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 30, y: 0, width: 270, height: 400))
            context.fill(CGRect(x: 0, y: 200, width: 30, height: 30))
        }
        // At most the outermost light line and one more go, never the 30 px band.
        #expect((ImageAnalysis.marginCrop(of: image)?[0] ?? 0) <= 2.0 / 300 + 0.001)
    }

    @Test func trimsOnePixelEdges() throws {
        // A one-pixel white line on the left and along the bottom; one more pixel goes too.
        let image = try page { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 1, y: 1, width: 299, height: 399))
        }
        let crop = try #require(ImageAnalysis.marginCrop(of: image))
        #expect(abs(crop[0] - 2.0 / 300) < 0.001)
        #expect(abs(crop[2] - 298.0 / 300) < 0.001)
        #expect(crop[1] == 0)
        #expect(abs(crop[3] - 398.0 / 400) < 0.001)
    }

    @Test func artReachingIntoABandIsNotAMargin() throws {
        // White across the top 10 px, but the art (hair, say) reaches up into it to 2 px from the top.
        let image = try page { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 390))
            context.fill(CGRect(x: 100, y: 390, width: 20, height: 8))
        }
        // At most the outermost white line and one more go, never the 10 px band.
        #expect((ImageAnalysis.marginCrop(of: image)?[1] ?? 0) <= 2.0 / 400 + 0.001)
    }

    @Test func trimsATintedEdgeLine() throws {
        // A one-pixel cream line down the left beside orange art: not grey, but light, so it goes.
        let image = try page { context in
            context.setFillColor(CGColor(red: 1, green: 0.93, blue: 0.78, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 400))
            context.setFillColor(CGColor(red: 1, green: 0.75, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 1, y: 0, width: 299, height: 400))
        }
        let crop = try #require(ImageAnalysis.marginCrop(of: image))
        #expect(abs(crop[0] - 2.0 / 300) < 0.001)
        #expect(abs(crop[2] - 298.0 / 300) < 0.001)
    }

    @Test func trimsThinTopAndBottomBandsOnly() throws {
        // A white band of 10 px at the top (2.5%) goes; one of 40 px at the bottom (10%) stays.
        let image = try page { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 40, width: 300, height: 350))
        }
        let crop = try #require(ImageAnalysis.marginCrop(of: image))
        #expect(crop[0] == 0 && crop[2] == 1)
        #expect(abs(crop[1] - 11.0 / 400) < 0.001)
        #expect(abs(crop[3] - 389.0 / 400) < 0.001)
    }

    /// A cover on the right half of a white two-page scan: more than half the width goes.
    @Test func trimsAWideBlankLeftHalf() throws {
        let crop = try #require(ImageAnalysis.marginCrop(of: try cover(left: 160, right: 20)))
        #expect(abs(crop[0] - 161.0 / 300) < 0.001)
        #expect(abs(crop[2] - 118.0 / 300) < 0.001)
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

    /// damaged.cbz: page1.png's compressed data is corrupt near its end; page2 and page3 are fine.
    /// One unreadable page must not blank the whole book or leave it without a cover.
    @Test func damagedPageDoesNotBreakTheRest() async throws {
        let source = try ArchiveBookSource(url: try fixture("damaged.cbz"), cacheRoot: try tempDir())
        #expect(source.pageCount == 3)
        // Page 1 either fails on its own or shows what could be read of it (libarchive versions differ).
        _ = try? await source.image(at: 0, maxPixelSize: 150)
        let second = try await source.image(at: 1, maxPixelSize: 150)
        #expect(second.height == 150)
        let third = try await source.image(at: 2, maxPixelSize: 150)
        #expect(third.height == 150)
    }

    @Test func coverFallsBackToNextReadablePage() async throws {
        let image = try await BookSourceFactory.firstPageImage(url: try fixture("damaged.cbz"), format: .zip, maxPixelSize: 60)
        #expect(image.height == 60)
    }

    @Test func badArchiveThrows() throws {
        let dir = try tempDir()
        let bad = dir.appendingPathComponent("bad.cbz")
        try Data("not an archive".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try ArchiveBookSource(url: bad, cacheRoot: dir) }
    }

    @Test func readsMetadataFromImageFoldersAndArchives() throws {
        let folder = try tempDir()
        try Data([1]).write(to: folder.appendingPathComponent("001.jpg"))
        try Data("<ComicInfo><Writer>Kozue Amano</Writer><Publisher>Mag Garden</Publisher></ComicInfo>".utf8)
            .write(to: folder.appendingPathComponent("ComicInfo.xml"))
        let info = try #require(MetadataReader.read(url: folder, format: .folder))
        #expect(info.writers == ["Kozue Amano"])
        #expect(info.publisher == "Mag Garden")

        // The sample archive's ComicInfo.xml has only a series, and every field is kept (#75).
        #expect(MetadataReader.read(url: try fixture("sample.cbz"), format: .zip)?.series == "Sample")

        let bad = folder.appendingPathComponent("bad.cbz")
        try Data("not an archive".utf8).write(to: bad)
        #expect(MetadataReader.read(url: bad, format: .zip) == nil)
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

/// Sharing a page (#60).
@Suite struct PageExportTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func exportsTheOriginalArchivePageUnderTheBookTitle() async throws {
        let source = try ArchiveBookSource(url: try fixture("sample.cbz"), cacheRoot: try tempDir())
        let file = try await PageExport.export(source, page: 2, title: "Night: Market / 2", to: try tempDir())
        #expect(file.lastPathComponent == "Night- Market - 2 - p3.png")
        let original = try await source.pageURL(at: 2)
        #expect(try Data(contentsOf: file) == Data(contentsOf: original))
    }

    @Test func exportsAPDFPageAtTheScannedImageSize() async throws {
        // A one-page PDF, 200 × 300 points, holding one 400 × 600 image.
        let url = try tempDir().appendingPathComponent("scan.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 300)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil as CFDictionary?))
        let bitmap = try #require(CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        let image = try #require(bitmap.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()

        let source = try PDFBookSource(url: url)
        let file = try await PageExport.export(source, page: 0, title: "Scan", to: try tempDir())
        #expect(file.lastPathComponent == "Scan - p1.jpg")
        let size = try #require(ImageDecoder.pixelSize(url: file))
        #expect(size == CGSize(width: 400, height: 600))
    }

    @Test func shareFileNames() {
        #expect(PageExport.fileName(title: "Saga 001", page: 11, ext: "jpg") == "Saga 001 - p12.jpg")
        #expect(PageExport.fileName(title: "  ", page: 0, ext: "png") == "Page - p1.png")
        #expect(PageExport.fileName(title: ".hidden", page: 0, ext: "png") == "hidden - p1.png")
    }
}
