import Foundation

/// Download and remove-from-device for iCloud Drive files. Removing only drops the local copy;
/// the file in iCloud is untouched.
public enum CloudFiles {
    public static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return LibraryScanner.isLocal(values) && FileManager.default.fileExists(atPath: url.path)
    }

    public static func isInCloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    public static func startDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Starts the download if needed and waits until the file is on the device.
    public static func download(_ url: URL, timeout: TimeInterval = 600) async throws {
        if isDownloaded(url) { return }
        try startDownload(url)
        let deadline = Date().addingTimeInterval(timeout)
        while !isDownloaded(url) {
            try Task.checkCancellation()
            if Date() > deadline { throw CocoaError(.ubiquitousFileUnavailable) }
            var check = url
            check.removeAllCachedResourceValues()
            if let error = (try? check.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?.ubiquitousItemDownloadingError {
                throw error
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    public static func evict(_ url: URL) throws {
        guard isInCloud(url) else { return }
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
