import ComicCore
import CoreGraphics
import Foundation

/// A readable book, whatever its container. Implementations are safe to call from any task;
/// all file and decode work happens off the main thread.
public protocol BookSource: AnyObject, Sendable {
    var pageCount: Int { get }
    /// Page image downsampled so its longest side is at most `maxPixelSize`.
    func image(at index: Int, maxPixelSize: CGFloat) async throws -> CGImage
    /// Pixel size of a page (cheap; reads only the image header).
    func pageSize(at index: Int) async throws -> CGSize
}

public enum BookSourceFactory {
    /// Opens a book that is already on the device.
    /// - Parameter cacheDirectory: where archive pages are unpacked (one folder per book).
    public static func open(url: URL, format: BookFormat, cacheDirectory: URL) async throws -> BookSource {
        try await Task.detached(priority: .userInitiated) { () throws -> BookSource in
            switch format {
            case .pdf:
                return try PDFBookSource(url: url)
            case .folder:
                return try FolderBookSource(url: url)
            case .zip, .rar, .sevenZip, .tar, .epub:
                return try ArchiveBookSource(url: url, cacheRoot: cacheDirectory)
            }
        }.value
    }

    /// Extracts the first page only, stopping early: used to make covers.
    public static func firstPageImage(url: URL, format: BookFormat, maxPixelSize: CGFloat) async throws -> CGImage {
        try await Task.detached(priority: .utility) { () throws -> CGImage in
            switch format {
            case .pdf:
                return try PDFBookSource(url: url).render(index: 0, maxPixelSize: maxPixelSize)
            case .folder:
                let source = try FolderBookSource(url: url)
                guard let first = source.pageURLs.first else { throw ArchiveError(message: "No pages") }
                return try ImageDecoder.downsample(url: first, maxPixelSize: maxPixelSize)
            case .zip, .rar, .sevenZip, .tar, .epub:
                // Find the first page by natural order, then read just that entry.
                guard let firstPath = try LibArchive.pagePaths(in: url).first else { throw ArchiveError(message: "No pages") }
                var data: Data?
                try LibArchive.forEachEntry(in: url) { path, reader in
                    guard path == firstPath else { return .next }
                    data = try reader.readAll()
                    return .stop
                }
                guard let data else { throw ArchiveError(message: "No pages") }
                return try ImageDecoder.downsample(data: data, maxPixelSize: maxPixelSize)
            }
        }.value
    }
}

// MARK: - Image folder

/// A folder that contains only images is read as one book.
public final class FolderBookSource: BookSource, @unchecked Sendable {
    public let pageURLs: [URL]
    public var pageCount: Int { pageURLs.count }

    public init(url: URL) throws {
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        pageURLs = contents
            .filter { PageFilter.isPage(path: $0.lastPathComponent) }
            .sorted { $0.lastPathComponent.naturalLess(than: $1.lastPathComponent) }
    }

    public func image(at index: Int, maxPixelSize: CGFloat) async throws -> CGImage {
        let url = pageURLs[index]
        return try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.downsample(url: url, maxPixelSize: maxPixelSize)
        }.value
    }

    public func pageSize(at index: Int) async throws -> CGSize {
        ImageDecoder.pixelSize(url: pageURLs[index]) ?? CGSize(width: 2, height: 3)
    }
}
