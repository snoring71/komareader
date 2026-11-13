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
    private struct Job { var book: Book; var fileURL: URL; var needsCloud: Bool }
    /// Books on the device, or with a shared cover already: cheap, so they go first.
    private var pendingLocal: [String] = []
    /// Books that have to be fetched from iCloud: one at a time, with a pause in between.
    private var pendingCloud: [String] = []
    private var jobs: [String: Job] = [:]
    private var running: Set<String> = []
    private var cloudRunning = 0
    private var nextCloudStart = Date.distantPast
    private var wakeTask: Task<Void, Never>?
    private var failed: Set<String> = []
    private var onCoverReady: (@Sendable (String, URL) -> Void)?
    /// When false, books that are not on the device wait (for Wi-Fi, a charger, and so on).
    public private(set) var allowsCloudDownloads = true
    /// Pause between two books fetched from iCloud, so a big library does not saturate the network.
    public var cloudPause: TimeInterval

    public init(store: RecordStore, thumbnailDirectory: URL, maxConcurrent: Int = 2, cloudPause: TimeInterval = 2) {
        self.store = store
        self.thumbnailDirectory = thumbnailDirectory
        self.maxConcurrent = maxConcurrent
        self.cloudPause = cloudPause
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    }

    public func setHandler(_ handler: @escaping @Sendable (String, URL) -> Void) {
        onCoverReady = handler
    }

    public func setAllowsCloudDownloads(_ allowed: Bool) {
        guard allowed != allowsCloudDownloads else { return }
        allowsCloudDownloads = allowed
        pump()
    }

    /// While paused, no new cover is started (covers already being made finish). The app pauses
    /// while a book is open, so making covers never competes with turning pages.
    public private(set) var isPaused = false

    public func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        pump()
    }

    /// Books still waiting to be fetched from iCloud for their covers.
    public var waitingForCloud: Int { pendingCloud.count }

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
        let needsCloud: Bool
        if let job = jobs[book.id] {
            needsCloud = job.needsCloud
            // Already queued: only move it up if it is on screen now.
            guard urgent else { return }
        } else {
            needsCloud = !book.isDownloaded && store.existingCoverURL(bookId: book.id) == nil
        }
        jobs[book.id] = Job(book: book, fileURL: fileURL, needsCloud: needsCloud)
        if needsCloud {
            pendingCloud.removeAll { $0 == book.id }
            if urgent { pendingCloud.insert(book.id, at: 0) } else { pendingCloud.append(book.id) }
        } else {
            pendingLocal.removeAll { $0 == book.id }
            if urgent { pendingLocal.insert(book.id, at: 0) } else { pendingLocal.append(book.id) }
        }
        pump()
    }

    /// Removes the local thumbnail so it is rebuilt (for example after a cover edit).
    public func invalidate(bookId: String) {
        try? FileManager.default.removeItem(at: thumbnailURL(bookId: bookId))
        failed.remove(bookId)
    }

    private func pump() {
        guard !isPaused else { return }
        while running.count < maxConcurrent, !pendingLocal.isEmpty {
            start(pendingLocal.removeFirst(), cloud: false)
        }
        guard allowsCloudDownloads, cloudRunning == 0, running.count < maxConcurrent, !pendingCloud.isEmpty else { return }
        let wait = nextCloudStart.timeIntervalSinceNow
        if wait > 0 {
            guard wakeTask == nil else { return }
            wakeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                await self?.wake()
            }
            return
        }
        start(pendingCloud.removeFirst(), cloud: true)
    }

    private func wake() {
        wakeTask = nil
        pump()
    }

    private func start(_ id: String, cloud: Bool) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        running.insert(id)
        if cloud { cloudRunning += 1 }
        Task.detached(priority: .utility) { [store, thumbnailDirectory] in
            let result = await Self.makeCover(book: job.book, fileURL: job.fileURL, store: store, thumbnailDirectory: thumbnailDirectory)
            await self.finish(id: id, thumbnail: result, cloud: cloud)
        }
    }

    private func finish(id: String, thumbnail: URL?, cloud: Bool) {
        running.remove(id)
        if cloud {
            cloudRunning -= 1
            nextCloudStart = Date().addingTimeInterval(cloudPause)
        }
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
