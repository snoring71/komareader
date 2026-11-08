import Foundation

/// Book container formats the app understands.
public enum BookFormat: String, Codable, Sendable, CaseIterable {
    case zip
    case rar
    case sevenZip = "7z"
    case tar
    case pdf
    case epub
    case folder

    public static func from(pathExtension ext: String) -> BookFormat? {
        switch ext.lowercased() {
        case "cbz", "zip": return .zip
        case "cbr", "rar": return .rar
        case "cb7", "7z": return .sevenZip
        case "cbt", "tar": return .tar
        case "pdf": return .pdf
        case "epub": return .epub
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .zip: return "CBZ"
        case .rar: return "CBR"
        case .sevenZip: return "CB7"
        case .tar: return "CBT"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        case .folder: return "Folder"
        }
    }

    /// Formats read through libarchive.
    public var isArchive: Bool {
        switch self {
        case .zip, .rar, .sevenZip, .tar, .epub: return true
        case .pdf, .folder: return false
        }
    }
}

public enum PageFilter {
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "jxl", "bmp", "tif", "tiff",
    ]

    /// True for archive entries or files that are comic pages (skips metadata, macOS junk and dotfiles).
    public static func isPage(path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let last = components.last else { return false }
        if components.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { return false }
        let ext = (String(last) as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }
}
