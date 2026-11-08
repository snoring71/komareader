import ArchiveKit
import ComicCore
import CoreGraphics
import Foundation

/// Makes covers. The shared cover (about 1200 px tall) goes into the synced data folder so
/// every device and app can show it without the book; small grid thumbnails stay local.
///
/// A book that only exists in iCloud is downloaded for its cover and then evicted again, so
/// the user never sees it appear on the device.
public actor CoverService {
    public static let sharedCoverHeight: CGFloat = 1200
    public static let thumbnailHeight: CGFloat = 420

    private let store: RecordStore
    private let thumbnailDirectory: URL
    private let maxConcurrent: Int
    private var pending: [String] = []
    private var jobs: [String: (Book, URL)] = [:]
    private var running: Set<String> = []
    private var failed: Set<String> = []
    private var onCoverReady: (@Sendable (String, URL) -> Void)?
    /// When false, books that are not on the device are skipped.
    public var allowsCloudDownloads = true

    public init(store: RecordStore, thumbnailDirectory: URL, maxConcurrent: Int = 2) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.maxConcurrent = maxConcurrent
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    }

    public func setHandler(_ handler: @escaping @Sendable (String, URL) -> Void) {
        onCoverReady = handler
    }

    public func setAllowsCloudDownloads(_ allowed: Bool) { allowsCloudDownloads = allowed }

    public nonisolated func thumbnailURL(bookId: String) -> URL {
        thumbnailDirectory.appendingPathComponent("\(bookId).jpg")
    }

    /// The local thumbnail if it exists already.
    public nonisolated func existingThumbnail(bookId: String) -> URL? {
        let url = thumbnailURL(bookId: bookId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Queues cover work. `urgent` books (on screen now) jump to the front.
    public func request(_ book: Book, fileURL: URL, urgent: Bool) {
        guard !book.isMissing, existingThumbnail(bookId: book.id) == nil, !failed.contains(book.id), !running.contains(book.id) else { return }
        jobs[book.id] = (book, fileURL)
        pending.removeAll { $0 == book.id }
        if urgent { pending.insert(book.id, at: 0) } else { pending.append(book.id) }
        pump()
    }

    /// Removes the local thumbnail so it is rebuilt (for example after a cover edit).
    public func invalidate(bookId: String) {
        try? FileManager.default.removeItem(at: thumbnailURL(bookId: bookId))
        failed.remove(bookId)
    }

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let job = jobs.removeValue(forKey: id) else { continue }
            let (book, url) = job
            if !book.isDownloaded && !allowsCloudDownloads && store.existingCoverURL(bookId: id) == nil { continue }
            running.insert(id)
            Task.detached(priority: .utility) { [store, thumbnailDirectory] in
                let result = await Self.makeCover(book: book, fileURL: url, store: store, thumbnailDirectory: thumbnailDirectory)
                await self.finish(id: id, thumbnail: result)
            }
        }
    }

    private func finish(id: String, thumbnail: URL?) {
        running.remove(id)
        if let thumbnail { onCoverReady?(id, thumbnail) } else { failed.insert(id) }
        pump()
    }

    private static func makeCover(book: Book, fileURL: URL, store: RecordStore, thumbnailDirectory: URL) async -> URL? {
        let thumbURL = thumbnailDirectory.appendingPathComponent("\(book.id).jpg")
        do {
            // 1. A cover made by another device (or the Windows app) is already synced.
            if let shared = store.existingCoverURL(bookId: book.id) {
                try writeThumbnail(from: try ImageDecoder.downsample(url: shared, maxPixelSize: thumbnailHeight), to: thumbURL)
                return thumbURL
            }
            // 2. Otherwise read the first page, fetching the book from iCloud if needed.
            let wasDownloaded = CloudFiles.isDownloaded(fileURL)
            if !wasDownloaded { try await CloudFiles.download(fileURL) }
            defer { if !wasDownloaded { try? CloudFiles.evict(fileURL) } }

            let cover = try await BookSourceFactory.firstPageImage(url: fileURL, format: book.format, maxPixelSize: sharedCoverHeight)
            guard let jpeg = ImageDecoder.jpegData(cover, quality: 0.85) else { return nil }
            try store.writeCover(jpeg, bookId: book.id)
            try writeThumbnail(from: try ImageDecoder.downsample(data: jpeg, maxPixelSize: thumbnailHeight), to: thumbURL)
            return thumbURL
        } catch {
            return nil
        }
    }

    private static func writeThumbnail(from image: CGImage, to url: URL) throws {
        guard let data = ImageDecoder.jpegData(image, quality: 0.8) else { throw ArchiveError(message: "Could not encode thumbnail") }
        try data.write(to: url, options: .atomic)
    }
}
