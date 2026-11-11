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
    private var failure: Error?
    private var extractionTask: Task<Void, Never>?

    public init(url: URL, cacheRoot: URL) throws {
        self.url = url
        self.pagePaths = try LibArchive.pagePaths(in: url)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.lastPathComponent)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        self.cacheDirectory = cacheRoot.appendingPathComponent(Self.stableHash(key), isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

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
            } else if let failure {
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
        do {
            try LibArchive.forEachEntry(in: url) { path, reader in
                if Task.isCancelled { return .stop }
                guard let index = indexByPath[path] else { return .next }
                let alreadyDone: Bool = { lock.lock(); defer { lock.unlock() }; return extracted[index] != nil }()
                if alreadyDone { return .next }
                let data = try reader.readAll()
                let file = pageFile(index)
                try data.write(to: file, options: .atomic)
                deliver(index: index, url: file)
                return .next
            }
            let missing: Bool = { lock.lock(); defer { lock.unlock() }; return extracted.count < pagePaths.count }()
            if missing, !Task.isCancelled {
                // Duplicate names or unreadable entries: fail the remaining waiters cleanly.
                fail(with: ArchiveError(message: "Some pages could not be read"))
            }
            touch()
        } catch {
            fail(with: error)
        }
    }

    private func deliver(index: Int, url: URL) {
        lock.lock()
        extracted[index] = url
        let pending = waiters.removeValue(forKey: index) ?? []
        lock.unlock()
        pending.forEach { $0.resume(returning: url) }
    }

    private func fail(with error: Error) {
        lock.lock()
        failure = error
        let pending = waiters.values.flatMap { $0 }
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(throwing: error) }
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
