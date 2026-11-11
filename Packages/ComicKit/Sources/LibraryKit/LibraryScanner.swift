import ComicCore
import Foundation

/// A book file found in the library folder, whether or not it is on this device.
public struct ScannedBook: Sendable, Hashable {
    /// Real location of the book (never the hidden `.icloud` placeholder).
    public var url: URL
    /// Path relative to the library folder, "/" separated.
    public var relativePath: String
    public var format: BookFormat
    public var size: Int64?
    public var modified: Date?
    public var isDownloaded: Bool

    public init(url: URL, relativePath: String, format: BookFormat, size: Int64?, modified: Date?, isDownloaded: Bool) {
        self.url = url
        self.relativePath = relativePath
        self.format = format
        self.size = size
        self.modified = modified
        self.isDownloaded = isDownloaded
    }

    public var title: String { ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension }
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

/// Walks the library folder and lists every book, including books that exist only in iCloud.
public enum LibraryScanner {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    public static func scan(root: URL) -> [ScannedBook] {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var books: [ScannedBook] = []
        walk(directory: root, rootPath: rootPath, into: &books)
        return books.sorted { $0.relativePath.naturalLess(than: $1.relativePath) }
    }

    private static func walk(directory: URL, rootPath: String, into books: inout [ScannedBook]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: []) else { return }

        var subdirectories: [URL] = []
        var imageCount = 0
        var otherFiles = 0
        var hasCloudOnlyImages = false
        let directoryRelative = relative(directory, rootPath)

        for item in items {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                if !name.hasPrefix(".") { subdirectories.append(item) }
                continue
            }

            // Older iCloud Drive keeps files that are not downloaded as hidden ".Name.cbz.icloud" placeholders.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                let realURL = directory.appendingPathComponent(realName)
                if let format = BookFormat.from(pathExtension: (realName as NSString).pathExtension) {
                    books.append(ScannedBook(
                        url: realURL, relativePath: join(directoryRelative, realName), format: format,
                        size: placeholderSize(item), modified: values?.contentModificationDate, isDownloaded: false
                    ))
                } else if PageFilter.isPage(path: realName) {
                    imageCount += 1
                    hasCloudOnlyImages = true
                }
                continue
            }
            if name.hasPrefix(".") { continue }

            if let format = BookFormat.from(pathExtension: item.pathExtension) {
                books.append(ScannedBook(
                    url: item, relativePath: join(directoryRelative, name), format: format,
                    size: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate,
                    isDownloaded: isLocal(values)
                ))
            } else if PageFilter.isPage(path: name) {
                imageCount += 1
                if !isLocal(values) { hasCloudOnlyImages = true }
            } else {
                otherFiles += 1
            }
        }

        // A folder holding only images (no sub-folders) is one book.
        if !directoryRelative.isEmpty, subdirectories.isEmpty, imageCount > 0, otherFiles == 0 {
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey])
            books.append(ScannedBook(
                url: directory, relativePath: directoryRelative, format: .folder,
                size: nil, modified: values?.contentModificationDate, isDownloaded: !hasCloudOnlyImages
            ))
            return
        }
        for sub in subdirectories { walk(directory: sub, rootPath: rootPath, into: &books) }
    }

    static func isLocal(_ values: URLResourceValues?) -> Bool {
        guard let values, values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus != .notDownloaded
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : "\(folder)/\(name)"
    }

    static func relative(_ url: URL, _ rootPath: String) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if path == rootPath { return "" }
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The `.icloud` placeholder is a small plist that records the real file size.
    private static func placeholderSize(_ url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["NSURLFileSizeKey"] as? NSNumber)?.int64Value
    }
}
