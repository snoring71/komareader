import ComicCore
import LibraryKit
import SwiftUI

enum SidebarItem: Hashable {
    case all, continueReading, series, unread, reading, read, favorites, bookmarked, missing
    case folder(String)
    case seriesNamed(String)

    var title: String {
        switch self {
        case .all: return "All Books"
        case .continueReading: return "Continue Reading"
        case .series: return "Series"
        case .favorites: return "Favorites"
        case .bookmarked: return "Bookmarked"
        case .seriesNamed(let name): return name
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
        case .series: return "square.stack"
        case .favorites: return "heart"
        case .bookmarked: return "bookmark"
        case .seriesNamed: return "square.stack"
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
        case .series: return !book.isMissing
        case .favorites: return !book.isMissing && book.favorite
        case .bookmarked: return !book.isMissing && book.bookmarked
        case .seriesNamed(let name): return !book.isMissing && book.series.caseInsensitiveCompare(name) == .orderedSame
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

/// Books grouped by series, for the Series view. Series are matched ignoring case.
struct SeriesGroup: Identifiable, Hashable {
    let name: String
    let books: [Book]
    var id: String { name.lowercased() }

    static func groups(from books: [Book]) -> [SeriesGroup] {
        let grouped = Dictionary(grouping: books.filter { !$0.isMissing }) { $0.series.lowercased() }
        return grouped.values.compactMap { members -> SeriesGroup? in
            let sorted = members.sorted(by: SeriesGroup.readingOrder)
            guard let first = sorted.first else { return nil }
            return SeriesGroup(name: first.series, books: sorted)
        }
        .sorted { $0.name.naturalLess(than: $1.name) }
    }

    /// Volume order: by number when both have one, else by title.
    static func readingOrder(_ a: Book, _ b: Book) -> Bool {
        if let x = a.number, let y = b.number, x != y { return x.naturalLess(than: y) }
        return a.title.naturalLess(than: b.title)
    }
}

/// The letter a title is filed under in the library's index: A to Z, a kana row (あ, か, さ…)
/// for Japanese titles in kana, 漢 for titles that start with a kanji, and # for the rest.
enum IndexKey {
    static func of(_ title: String) -> String {
        guard let first = title.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).uppercased()
        if let scalar = folded.unicodeScalars.first, folded.unicodeScalars.count == 1, ("A"..."Z").contains(scalar) {
            return folded
        }
        var value = first.value
        if (0x30A1...0x30F6).contains(value) { value -= 0x60 } // katakana to hiragana
        let rows: [(ClosedRange<UInt32>, String)] = [
            (0x3041...0x304A, "あ"), (0x304B...0x3054, "か"), (0x3055...0x305E, "さ"), (0x305F...0x3069, "た"),
            (0x306A...0x306E, "な"), (0x306F...0x307D, "は"), (0x307E...0x3082, "ま"), (0x3083...0x3088, "や"),
            (0x3089...0x308D, "ら"), (0x308E...0x3093, "わ"), (0x3094...0x3094, "あ"), (0x3095...0x3096, "か"),
        ]
        if let row = rows.first(where: { $0.0.contains(value) }) { return row.1 }
        if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) { return "漢" }
        return "#"
    }
}
