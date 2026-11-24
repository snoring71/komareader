import ComicCore
import CoreGraphics
import Foundation

/// CBZ, CBR, CB7, CBT (and image EPUBs) through libarchive.
///
/// RAR and 7z archives are usually solid, so pages cannot be read out of order cheaply.
/// We therefore unpack every page once into a per-book cache folder in a background task,
/// in archive order, and hand out each page as soon as its file is written.
public final class ArchiveBookSource: BookSource, @unchecked Sendable {
    public let url: URL
    public let pagePaths: [String]
    public var pageCount: Int { pagePaths.count }

    private let cacheDirectory: URL
    private let lock = NSLock()
    private var extracted: [Int: URL] = [:]
    private var waiters: [Int: [CheckedContinuation<URL, Error>]] = [:]
    /// Pages that could not be read. One bad page no longer takes the rest of the book with it.
    private var failures: [Int: Error] = [:]
    /// Set once extraction has ended; pages still missing then fail with this.
    private var finalFailure: Error?
    private var extractionTask: Task<Void, Never>?

    /// - Parameter unpackWhileListing: keep each page's bytes while listing the archive, for RAR
    ///   and 7z. Those are usually solid, so listing them unpacks the whole book anyway, and
    ///   unpacking it a second time to save the pages took twice as long and twice the battery.
    public init(url: URL, cacheRoot: URL, unpackWhileListing: Bool = false) throws {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let cacheDirectory = cacheRoot.appendingPathComponent(Self.stableHash(key), isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDirectory

        // The page list from an earlier open: the folder is named for this exact file (name,
        // size and date), so it still holds. Without it, opening a book again listed the whole
        // archive again, which for a solid one meant unpacking it all just to count pages.
        let manifest = cacheDirectory.appendingPathComponent(Self.manifestName)
        var staged: [String: URL] = [:]
        let staging = cacheDirectory.appendingPathComponent("staging", isDirectory: true)
        if let data = try? Data(contentsOf: manifest), let paths = try? JSONDecoder().decode([String].self, from: data) {
            self.pagePaths = paths
        } else {
            if unpackWhileListing, let listed = try? Self.listAndStage(url: url, into: staging) {
                self.pagePaths = listed.paths
                staged = listed.staged
            } else {
                self.pagePaths = try LibArchive.pagePaths(in: url)
            }
            if let data = try? JSONEncoder().encode(pagePaths) { try? data.write(to: manifest, options: .atomic) }
        }
        // Pages kept while listing go to their place in reading order.
        if !staged.isEmpty {
            let fm = FileManager.default
            for (index, path) in pagePaths.enumerated() {
                guard let file = staged.removeValue(forKey: path) else { continue }
                let target = pageFile(index)
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: file, to: target)
            }
        }
        try? FileManager.default.removeItem(at: staging)

        // Reuse pages unpacked earlier.
        for index in pagePaths.indices {
            let file = pageFile(index)
            if FileManager.default.fileExists(atPath: file.path) { extracted[index] = file }
        }
        if extracted.count < pagePaths.count {
            extractionTask = Task.detached(priority: .userInitiated) { [weak self] in self?.extractAll() }
        } else {
            touch()
        }
    }

    deinit { extractionTask?.cancel() }

    public func image(at index: Int, maxPixelSize: CGFloat) async throws -> CGImage {
        let file = try await pageURL(at: index)
        return try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.downsample(url: file, maxPixelSize: maxPixelSize)
        }.value
    }

    public func pageSize(at index: Int) async throws -> CGSize {
        let file = try await pageURL(at: index)
        return ImageDecoder.pixelSize(url: file) ?? CGSize(width: 2, height: 3)
    }

    /// Waits until the page has been unpacked.
    public func pageURL(at index: Int) async throws -> URL {
        guard pagePaths.indices.contains(index) else { throw ArchiveError(message: "No page \(index + 1)") }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let url = extracted[index] {
                lock.unlock()
                continuation.resume(returning: url)
            } else if let failure = failures[index] ?? finalFailure {
                lock.unlock()
                continuation.resume(throwing: failure)
            } else {
                waiters[index, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    private func pageFile(_ index: Int) -> URL {
        let ext = (pagePaths[index] as NSString).pathExtension.lowercased()
        return cacheDirectory.appendingPathComponent(String(format: "%05d.%@", index, ext))
    }

    private func extractAll() {
        let indexByPath = Dictionary(pagePaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // libarchive can fail on a single entry (its RAR5 reader trips on some valid archives)
        // and may not carry on reliably after that. So when a page fails, keep what was read of
        // it, then start a fresh pass from the top that skips the pages already settled. Each
        // pass settles at least one more page or ends the loop.
        var lastError: Error?
        while !Task.isCancelled {
            var hitBadPage = false
            var progressed = false
            do {
                try LibArchive.forEachEntry(in: url) { path, reader in
                    if Task.isCancelled { return .stop }
                    guard let index = indexByPath[path], !isSettled(index) else { return .next }
                    let (data, error) = reader.readAvailable()
                    progressed = true
                    if let error {
                        hitBadPage = true
                        lastError = error
                        // A page cut short near the end still shows nearly all of it.
                        if !data.isEmpty, ImageDecoder.canDecode(data: data), (try? write(data, index: index)) != nil {
                            return .stop
                        }
                        markFailed(index: index, error: error)
                        return .stop
                    }
                    try write(data, index: index)
                    return .next
                }
            } catch {
                // The archive itself could not be read any further.
                lastError = error
                break
            }
            if !hitBadPage || !progressed { break }
        }
        if Task.isCancelled { return }
        let missing: Bool = { lock.lock(); defer { lock.unlock() }; return extracted.count + failures.count < pagePaths.count }()
        if missing {
            // Duplicate names or entries past an unreadable spot: fail the remaining waiters cleanly.
            finish(with: lastError ?? ArchiveError(message: "Some pages could not be read"))
        }
        touch()
    }

    private func isSettled(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return extracted[index] != nil || failures[index] != nil
    }

    private func write(_ data: Data, index: Int) throws {
        let file = pageFile(index)
        try data.write(to: file, options: .atomic)
        deliver(index: index, url: file)
    }

    private func deliver(index: Int, url: URL) {
        lock.lock()
        extracted[index] = url
        let pending = waiters.removeValue(forKey: index) ?? []
        lock.unlock()
        pending.forEach { $0.resume(returning: url) }
    }

    private func markFailed(index: Int, error: Error) {
        lock.lock()
        failures[index] = error
        let pending = waiters.removeValue(forKey: index) ?? []
        lock.unlock()
        pending.forEach { $0.resume(throwing: error) }
    }

    private func finish(with error: Error) {
        lock.lock()
        finalFailure = error
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(throwing: error) }
    }

    private static let manifestName = "pages.json"

    /// Lists the archive's pages in one pass, writing each page's bytes into `directory` (named
    /// by archive position) as it goes. Throws if any page cannot be read, leaving nothing
    /// behind: the usual list-then-extract path handles damaged archives page by page.
    private static func listAndStage(url: URL, into directory: URL) throws -> (paths: [String], staged: [String: URL]) {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        var staged: [String: URL] = [:]
        var failed = false
        do {
            try LibArchive.forEachEntry(in: url) { path, reader in
                guard PageFilter.isPage(path: path) else { return .next }
                paths.append(path)
                guard staged[path] == nil else { return .next }
                let read = reader.readAvailable()
                if read.error != nil {
                    failed = true
                    return .stop
                }
                let file = directory.appendingPathComponent(String(format: "%05d", paths.count - 1))
                try read.data.write(to: file)
                staged[path] = file
                return .next
            }
        } catch {
            failed = true
        }
        if failed {
            try? fm.removeItem(at: directory)
            throw ArchiveError(message: "Could not unpack \(url.lastPathComponent) in one pass")
        }
        return (PageOrder.sorted(paths), staged)
    }

    /// Marks the cache folder as recently used (for future LRU cleanup).
    private func touch() {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheDirectory.path)
    }

    /// FNV-1a, stable across launches (unlike Hasher).
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}
