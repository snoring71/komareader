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
    /// when iCloud is off. Call off the main thread: the first lookup can be slow.
    public static func appDataRoot() -> (url: URL, isCloud: Bool) {
        if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            return (documents, true)
        }
        let local = URL.applicationSupportDirectory.appendingPathComponent("Comic Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        return (local, false)
    }
}
