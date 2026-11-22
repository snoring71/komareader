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
        try await firstPage(url: url, format: format, maxPixelSize: maxPixelSize, wantsMetadata: false).image
    }

    /// The first page, and the file's own metadata when `wantsMetadata` (nil if it could not be
    /// read), read together: for an archive that is usually one pass instead of three.
    public static func firstPage(url: URL, format: BookFormat, maxPixelSize: CGFloat, wantsMetadata: Bool) async throws -> (image: CGImage, metadata: BookData?) {
        try await Task.detached(priority: .utility) { () throws -> (image: CGImage, metadata: BookData?) in
            switch format {
            case .pdf:
                let image = try PDFBookSource(url: url).render(index: 0, maxPixelSize: maxPixelSize)
                return (image, wantsMetadata ? MetadataReader.read(url: url, format: format) : nil)
            case .folder:
                let source = try FolderBookSource(url: url)
                guard let first = source.pageURLs.first else { throw ArchiveError(message: "No pages") }
                let image = try ImageDecoder.downsample(url: first, maxPixelSize: maxPixelSize)
                return (image, wantsMetadata ? MetadataReader.read(url: url, format: format) : nil)
            case .zip, .rar, .sevenZip, .tar, .epub:
                return try archiveFirstPage(url: url, format: format, maxPixelSize: maxPixelSize, wantsMetadata: wantsMetadata)
            }
        }.value
    }

    private static func archiveFirstPage(url: URL, format: BookFormat, maxPixelSize: CGFloat, wantsMetadata: Bool) throws -> (image: CGImage, metadata: BookData?) {
        let scan = try? LibArchive.coverScan(in: url, wantsComicInfo: wantsMetadata)
        let metadata: () -> BookData? = {
            guard wantsMetadata else { return nil }
            if let scan, scan.complete { return scan.comicInfo.flatMap(BookData.comicInfo) ?? BookData() }
            return MetadataReader.read(url: url, format: format)
        }
        // Most archives keep the first page first, so the scan already holds it.
        if let scan, scan.complete, let entry = scan.firstEntry, entry.path == scan.pagePaths.first,
           let image = try? ImageDecoder.downsample(data: entry.data, maxPixelSize: maxPixelSize) {
            return (image, metadata())
        }
        // Find the first page by natural order, then read just that entry. If it cannot be
        // read at all, the next readable page makes the cover rather than leaving none.
        let paths: [String]
        if let scan, scan.complete { paths = scan.pagePaths } else { paths = try LibArchive.pagePaths(in: url) }
        guard !paths.isEmpty else { throw ArchiveError(message: "No pages") }
        var lastError: Error = ArchiveError(message: "No pages")
        for wanted in paths.prefix(3) {
            var data: Data?
            do {
                try LibArchive.forEachEntry(in: url) { path, reader in
                    guard path == wanted else { return .next }
                    let read = reader.readAvailable()
                    // A page cut short near the end still makes a fine cover.
                    if read.error == nil || !read.data.isEmpty { data = read.data }
                    if let error = read.error { lastError = error }
                    return .stop
                }
            } catch {
                lastError = error
            }
            if let data, let image = try? ImageDecoder.downsample(data: data, maxPixelSize: maxPixelSize) {
                return (image, metadata())
            }
        }
        throw lastError
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
            .naturallySorted(by: \.lastPathComponent)
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
