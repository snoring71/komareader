import CArchive
import ComicCore
import Foundation

public struct ArchiveError: Error, LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thin wrapper over libarchive's streaming read API.
enum LibArchive {
    private static let regularFile: UInt32 = 0o100000
    private static let fileTypeMask: UInt32 = 0o170000

    /// Calls `body` for every regular file in the archive, in archive order.
    /// `body` gets the entry path and a reader; return `.stop` to finish early.
    static func forEachEntry(
        in url: URL,
        _ body: (_ path: String, _ reader: EntryReader) throws -> IterationAction
    ) throws {
        guard let archive = archive_read_new() else { throw ArchiveError(message: "libarchive unavailable") }
        defer { archive_read_free(archive) }
        archive_read_support_format_all(archive)
        archive_read_support_filter_all(archive)

        guard archive_read_open_filename(archive, url.path, 1 << 16) == ARCHIVE_OK else {
            throw error(archive, "Could not open \(url.lastPathComponent)")
        }

        var entry: OpaquePointer?
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw error(archive, "Could not read \(url.lastPathComponent)") }
            guard let entry else { continue }
            let type = UInt32(archive_entry_filetype(entry)) & fileTypeMask
            guard type == regularFile else { continue }
            let rawPath = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            guard let rawPath else { continue }
            let path = String(cString: rawPath)
            let reader = EntryReader(archive: archive)
            let action = try body(path, reader)
            if action == .stop { break }
            if !reader.consumed { archive_read_data_skip(archive) }
        }
    }

    enum IterationAction { case next, stop }

    final class EntryReader {
        fileprivate let archive: OpaquePointer
        fileprivate(set) var consumed = false
        fileprivate init(archive: OpaquePointer) { self.archive = archive }

        /// Reads the current entry's bytes.
        func readAll() throws -> Data {
            let (data, error) = readAvailable()
            if let error { throw error }
            return data
        }

        /// Reads as much of the current entry as libarchive can decode. When it fails partway
        /// (a decoder bug or a damaged archive) this returns the bytes read so far and the error,
        /// so a page that is only cut short at the end can still be shown.
        func readAvailable() -> (data: Data, error: ArchiveError?) {
            consumed = true
            var data = Data()
            let bufferSize = 1 << 16
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
            defer { buffer.deallocate() }
            while true {
                let count = archive_read_data(archive, buffer, bufferSize)
                if count == 0 { break }
                if count < 0 { return (data, LibArchive.error(archive, "Could not extract page")) }
                data.append(buffer.assumingMemoryBound(to: UInt8.self), count: Int(count))
            }
            return (data, nil)
        }
    }

    /// Page entry paths in reading order.
    static func pagePaths(in url: URL) throws -> [String] {
        var paths: [String] = []
        try forEachEntry(in: url) { path, _ in
            if PageFilter.isPage(path: path) { paths.append(path) }
            return .next
        }
        return PageOrder.sorted(paths)
    }

    /// What a cover needs from an archive, in one pass where it can: the pages in reading
    /// order, the bytes of the first page met in archive order, and the ComicInfo.xml bytes.
    /// RAR and 7z archives are usually solid, so each pass over one unpacks the whole book;
    /// listing, then reading the first page, then looking for ComicInfo.xml took up to three.
    struct CoverScan {
        var pagePaths: [String] = []
        var firstEntry: (path: String, data: Data, error: ArchiveError?)?
        var comicInfo: Data?
        /// False when an entry could not be read and the pass stopped early: the page list
        /// may be short then, so the caller goes the slower way.
        var complete = true
    }

    static func coverScan(in url: URL, wantsComicInfo: Bool) throws -> CoverScan {
        var scan = CoverScan()
        var paths: [String] = []
        try forEachEntry(in: url) { path, reader in
            if PageFilter.isPage(path: path) {
                paths.append(path)
                if scan.firstEntry == nil {
                    let read = reader.readAvailable()
                    scan.firstEntry = (path, read.data, read.error)
                    // A damaged entry may leave libarchive unable to carry on; the caller reads
                    // the rest with a pass of its own.
                    if read.error != nil {
                        scan.complete = false
                        return .stop
                    }
                }
            } else if wantsComicInfo, scan.comicInfo == nil, BookData.isComicInfo(path: path) {
                guard let data = try? reader.readAll() else {
                    scan.complete = false
                    return .stop
                }
                scan.comicInfo = data
            }
            return .next
        }
        scan.pagePaths = PageOrder.sorted(paths)
        return scan
    }

    fileprivate static func error(_ archive: OpaquePointer, _ fallback: String) -> ArchiveError {
        if let cString = archive_error_string(archive) {
            return ArchiveError(message: "\(fallback): \(String(cString: cString))")
        }
        return ArchiveError(message: fallback)
    }
}
