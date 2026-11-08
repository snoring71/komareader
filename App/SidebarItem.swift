import ComicCore
import LibraryKit
import SwiftUI

enum SidebarItem: Hashable {
    case all, continueReading, unread, reading, read, missing
    case folder(String)

    var title: String {
        switch self {
        case .all: return "All Books"
        case .continueReading: return "Continue Reading"
        case .unread: return "Unread"
        case .reading: return "Reading"
        case .read: return "Read"
        case .missing: return "Missing Files"
        case .folder(let path): return (path as NSString).lastPathComponent
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "books.vertical"
        case .continueReading: return "book"
        case .unread: return "circle"
        case .reading: return "circle.lefthalf.filled"
        case .read: return "checkmark.circle"
        case .missing: return "questionmark.folder"
        case .folder: return "folder"
        }
    }

    func includes(_ book: Book) -> Bool {
        switch self {
        case .all: return !book.isMissing
        case .continueReading: return !book.isMissing && book.status == .reading
        case .unread: return !book.isMissing && book.status == .unread
        case .reading: return !book.isMissing && book.status == .reading
        case .read: return !book.isMissing && book.status == .read
        case .missing: return book.isMissing
        case .folder(let path): return !book.isMissing && (book.folder == path || book.folder.hasPrefix(path + "/"))
        }
    }
}

/// Folder tree for the sidebar, built from the books' folder paths.
struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    var count: Int
    var children: [FolderNode]?

    static func tree(from books: [Book]) -> [FolderNode] {
        var counts: [String: Int] = [:]
        for book in books where !book.isMissing && !book.folder.isEmpty {
            var path = ""
            for part in book.folder.split(separator: "/") {
                path = path.isEmpty ? String(part) : "\(path)/\(part)"
                counts[path, default: 0] += 1
            }
        }
        func children(of parent: String) -> [FolderNode]? {
            let prefix = parent.isEmpty ? "" : parent + "/"
            let direct = counts.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") && $0 != parent }
            guard !direct.isEmpty else { return nil }
            return direct.sorted { $0.naturalLess(than: $1) }.map { path in
                FolderNode(id: path, name: (path as NSString).lastPathComponent, count: counts[path] ?? 0, children: children(of: path))
            }
        }
        return children(of: "") ?? []
    }
}
