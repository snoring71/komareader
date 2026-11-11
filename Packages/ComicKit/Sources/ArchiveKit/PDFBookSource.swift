import CoreGraphics
import Foundation
import PDFKit

/// PDF comics, rendered page by page at the size they are shown.
public final class PDFBookSource: BookSource, @unchecked Sendable {
    private let document: PDFDocument
    private let lock = NSLock()
    public let pageCount: Int

    public init(url: URL) throws {
        guard let document = PDFDocument(url: url) else { throw ArchiveError(message: "Could not open PDF") }
        self.document = document
        self.pageCount = document.pageCount
    }

    public func image(at index: Int, maxPixelSize: CGFloat) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) { [self] in
            try render(index: index, maxPixelSize: maxPixelSize)
        }.value
    }

    public func pageSize(at index: Int) async throws -> CGSize {
        lock.withLock { document.page(at: index)?.bounds(for: .mediaBox).size } ?? CGSize(width: 2, height: 3)
    }

    func render(index: Int, maxPixelSize: CGFloat) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        guard let page = document.page(at: index) else { throw ArchiveError(message: "No page \(index + 1)") }
        let bounds = page.bounds(for: .mediaBox)
        let scale = maxPixelSize / max(bounds.width, bounds.height, 1)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ArchiveError(message: "Out of memory") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ArchiveError(message: "Could not render page") }
        return image
    }
}
