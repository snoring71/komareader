import ComicCore
import Foundation

/// Remembers the library folder the user picked, across launches, with a bookmark.
public enum LibraryLocation {
    private static let bookmarkKey = "ComicReader.libraryBookmark"

    public static func save(_ url: URL, defaults: UserDefaults = .standard) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: bookmarkKey)
    }

    /// Resolves the saved folder and starts security-scoped access to it.
    public static func restore(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if stale { try? save(url, defaults: defaults) }
        return url
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// The app's own iCloud Drive folder ("iCloud Drive/Comic Reader"), or a local fallback
    /// when iCloud is off (or the build has no iCloud, see FREE_ACCOUNT in project.yml).
    /// Call off the main thread: the first lookup can be slow.
    ///
    /// This is the only place that decides whether data syncs. Everything else reads and writes
    /// the same files either way, so turning iCloud on needs no other change. When iCloud is
    /// available and data was kept on the device before, it is merged into iCloud once.
    public static func appDataRoot() -> (url: URL, isCloud: Bool) {
        let local = localDataRoot
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            importLocalData(from: local, into: documents)
            return (documents, true)
        }
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        return (local, false)
    }

    static var localDataRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Comic Reader", isDirectory: true)
    }

    /// Moves data kept on the device (records and covers in `local/Libraries`) into iCloud,
    /// merging with whatever other devices have already synced. Afterwards the local folder is
    /// renamed so this runs once; it stays on the device as a backup. Comics in `local/Books`
    /// are not touched.
    static func importLocalData(from local: URL, into cloudRoot: URL) {
        let fm = FileManager.default
        let libraries = local.appendingPathComponent("Libraries", isDirectory: true)
        guard fm.fileExists(atPath: libraries.path) else { return }
        do {
            try RecordStore.importLibraries(from: local, into: cloudRoot)
            let backup = local.appendingPathComponent("Libraries (copied to iCloud)", isDirectory: true)
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: libraries, to: backup)
        } catch {
            // Leave the local data where it is; we try again on the next launch.
        }
    }
}
