import ComicCore
import LibraryKit
import SwiftUI

enum SidebarItem: Hashable {
    case all, continueReading, series, folders, downloaded, unread, reading, read, favorites, bookmarked, missing
    /// Browse by author and by publisher (#78).
    case authors, publishers
    /// The books directly in a folder (subfolders are shown above them).
    case folder(String)
    case seriesNamed(String)
    case tag(String)
    /// One author's or publisher's books (#78). An empty name is the books with none.
    case author(String)
    case publisher(String)
    /// A reading list, by its id (#83).
    case readingList(String)

    /// Reading list names by id, kept up to date by the model, so a list's row and title can
    /// show its current name while the item itself (and pins of it) keep only the id.
    nonisolated(unsafe) static var listNames: [String: String] = [:]

    /// A string for saving the item between launches.
    var storageKey: String {
        switch self {
        case .folder(let path): return "folder:" + path
        case .seriesNamed(let name): return "series:" + name
        case .tag(let name): return "tag:" + name
        case .author(let name): return "author:" + name
        case .publisher(let name): return "publisher:" + name
        case .readingList(let id): return "list:" + id
        default: return "\(self)"
        }
    }

    init?(storageKey key: String) {
        if key.hasPrefix("folder:") {
            self = .folder(String(key.dropFirst("folder:".count)))
        } else if key.hasPrefix("series:") {
            self = .seriesNamed(String(key.dropFirst("series:".count)))
        } else if key.hasPrefix("tag:") {
            self = .tag(String(key.dropFirst("tag:".count)))
        } else if key.hasPrefix("author:") {
            self = .author(String(key.dropFirst("author:".count)))
        } else if key.hasPrefix("publisher:") {
            self = .publisher(String(key.dropFirst("publisher:".count)))
        } else if key.hasPrefix("list:") {
            self = .readingList(String(key.dropFirst("list:".count)))
        } else if let item = Self.plain.first(where: { "\($0)" == key }) {
            self = item
        } else {
            return nil
        }
    }

    /// Folders and series can be pinned to the sidebar (#72).
    var isPinnable: Bool {
        switch self {
        case .folder, .seriesNamed, .author, .publisher, .readingList: return true
        default: return false
        }
    }

    private static let plain: [SidebarItem] = [.all, .continueReading, .series, .folders, .downloaded, .unread, .reading, .read, .favorites, .bookmarked, .missing, .authors, .publishers]

    var title: String {
        switch self {
        case .all: return "All Books"
        case .continueReading: return "Continue Reading"
        case .series: return "Series"
        case .folders: return "Folders"
        case .downloaded: return "Downloaded"
        case .favorites: return "Favorites"
        case .bookmarked: return "Bookmarked"
        case .seriesNamed(let name): return name
        case .unread: return "Unread"
        case .reading: return "Reading"
        case .read: return "Read"
        case .missing: return "Missing Files"
        case .folder(let path): return (path as NSString).lastPathComponent
        case .tag(let name): return name
        case .authors: return "Authors"
        case .publishers: return "Publishers"
        case .author(let name): return name.isEmpty ? "Unknown Author" : name
        case .publisher(let name): return name.isEmpty ? "Unknown Publisher" : name
        case .readingList(let id): return Self.listNames[id] ?? "Reading List"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "books.vertical"
        case .continueReading: return "book"
        case .series: return "square.stack"
        case .folders: return "folder"
        case .downloaded: return "arrow.down.circle"
        case .favorites: return "heart"
        case .bookmarked: return "bookmark"
        case .seriesNamed: return "square.stack"
        case .unread: return "circle"
        case .reading: return "circle.lefthalf.filled"
        case .read: return "checkmark.circle"
        case .missing: return "questionmark.folder"
        case .folder: return "folder"
        case .tag: return "tag"
        case .authors, .author: return "person.2"
        case .publishers, .publisher: return "building.columns"
        case .readingList: return "list.number"
        }
    }

    func includes(_ book: Book) -> Bool {
        switch self {
        case .all: return !book.isMissing
        case .continueReading: return !book.isMissing && book.status == .reading
        case .series, .folders: return !book.isMissing
        case .downloaded: return !book.isMissing && book.isDownloaded
        case .favorites: return !book.isMissing && book.favorite
        case .bookmarked: return !book.isMissing && book.hasBookmarks
        case .seriesNamed(let name): return !book.isMissing && book.series.caseInsensitiveCompare(name) == .orderedSame
        case .unread: return !book.isMissing && book.status == .unread
        case .reading: return !book.isMissing && book.status == .reading
        case .read: return !book.isMissing && book.status == .read
        case .missing: return book.isMissing
        case .folder(let path): return !book.isMissing && book.folder == path
        case .tag(let name): return !book.isMissing && book.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        case .authors, .publishers: return !book.isMissing
        case .author(let name):
            guard !book.isMissing else { return false }
            return name.isEmpty ? book.authors.isEmpty : book.authors.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        case .publisher(let name):
            guard !book.isMissing else { return false }
            return name.isEmpty ? book.publisher == nil : book.publisher?.caseInsensitiveCompare(name) == .orderedSame
        // A reading list's books come from the list itself (`AppModel.listBooks`).
        case .readingList: return false
        }
    }
}

/// A folder that holds books, for the folder browser.
struct FolderInfo: Hashable, Identifiable {
    let path: String
    let name: String
    /// Books in the folder and its subfolders.
    var count = 0
    /// Books directly in the folder.
    var directCount = 0
    /// Subfolder paths, in natural order.
    var children: [String] = []
    /// The first book by title in the folder or below, whose cover stands for the folder.
    var coverBookId: String?
    fileprivate var coverRank = Int.max
    var id: String { path }

    /// All folders in one pass over the books (a big library has hundreds of folders).
    static func tree(from books: [Book], titleRank: [String: Int]) -> [String: FolderInfo] {
        var folders: [String: FolderInfo] = ["": FolderInfo(path: "", name: "")]
        for book in books where !book.isMissing && !book.folder.isEmpty {
            let rank = titleRank[book.id] ?? .max
            let parts = book.folder.split(separator: "/")
            var parent = ""
            for (i, part) in parts.enumerated() {
                let path = parent.isEmpty ? String(part) : parent + "/" + part
                if folders[path] == nil {
                    folders[path] = FolderInfo(path: path, name: String(part))
                    folders[parent]?.children.append(path)
                }
                folders[path]!.count += 1
                if i == parts.count - 1 { folders[path]!.directCount += 1 }
                if rank < folders[path]!.coverRank {
                    folders[path]!.coverRank = rank
                    folders[path]!.coverBookId = book.id
                }
                parent = path
            }
        }
        for key in Array(folders.keys) where folders[key]!.children.count > 1 {
            folders[key]!.children = folders[key]!.children.naturallySorted()
        }
        return folders
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
        .naturallySorted(by: \.name)
    }

    /// Books grouped by author (a book with several is under each) or by publisher, for the
    /// Authors and Publishers views (#78). Books with none are in a last group named "".
    static func groups(from books: [Book], by names: (Book) -> [String]) -> [SeriesGroup] {
        var grouped: [String: [Book]] = [:]
        var spelling: [String: String] = [:]
        for book in books where !book.isMissing {
            let keys = names(book)
            if keys.isEmpty {
                grouped["", default: []].append(book)
                continue
            }
            for name in keys {
                let key = name.lowercased()
                grouped[key, default: []].append(book)
                if spelling[key] == nil { spelling[key] = name }
            }
        }
        let unknown = grouped.removeValue(forKey: "")
        var result = grouped.map { key, members in
            SeriesGroup(name: spelling[key] ?? key, books: members.sorted(by: Self.bySeries))
        }
        .naturallySorted(by: \.name)
        if let unknown { result.append(SeriesGroup(name: "", books: unknown.sorted(by: Self.bySeries))) }
        return result
    }

    /// By series, then volume order within a series.
    static func bySeries(_ a: Book, _ b: Book) -> Bool {
        if a.series.caseInsensitiveCompare(b.series) != .orderedSame { return a.series.naturalLess(than: b.series) }
        return readingOrder(a, b)
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
