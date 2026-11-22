import ComicCore
import LibraryKit
import SwiftUI

/// The folders in the library as a grid of covers, opened from the Folders sidebar row. Tapping
/// a folder shows its subfolders and books. Search looks through every folder, at any depth.
struct FolderBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showSettings = false
    @AppStorage("folderSortOrder") private var sort: LibraryGridView.SortOrder = .title
    @AppStorage("coverSize") private var coverSize: Double = 150
    @AppStorage(TitleGrid.folders.key) private var showTitles = true
    /// Keeps the grid's place for the session, for coming back to it (#105).
    @State private var keeper = ScrollKeeper()

    private var folders: [FolderInfo] {
        let all = model.catalog.folders
        var folders: [FolderInfo]
        if search.isEmpty {
            folders = (all[""]?.children ?? []).compactMap { all[$0] }
        } else {
            let query = SearchQuery(search)
            let model = model
            _ = model.searchKeysRevision
            folders = all.values.filter { !$0.path.isEmpty && query.matches(model.searchKey($0.name)) }
                .naturallySorted(by: \.name)
        }
        switch sort {
        case .recentlyAdded:
            let latest = latestDates { $0.addedAt }
            folders.sort { (latest[$0.path] ?? .distantPast) > (latest[$1.path] ?? .distantPast) }
        case .recentlyRead:
            let latest = latestDates { $0.lastReadAt }
            folders.sort { (latest[$0.path] ?? .distantPast) > (latest[$1.path] ?? .distantPast) }
        default:
            // By name; the other orders are for books.
            break
        }
        return folders
    }

    /// The newest date among each folder's books, subfolders included, in one pass.
    private func latestDates(_ date: (Book) -> Date?) -> [String: Date] {
        var latest: [String: Date] = [:]
        for book in model.books where !book.isMissing && !book.folder.isEmpty {
            guard let value = date(book) else { continue }
            var path = Substring(book.folder)
            while true {
                let key = String(path)
                // A folder's date is never older than its subfolders', so its parents are done too.
                if let current = latest[key], current >= value { break }
                latest[key] = value
                guard let slash = path.lastIndex(of: "/") else { break }
                path = path[..<slash]
            }
        }
        return latest
    }

    var body: some View {
        let folders = folders
        let letters = letterAnchors(folders)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ScrollTopMarker()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(folders) { FolderLink(folder: $0, showsPath: !search.isEmpty) }
                    }
                    .scrollTargetLayout()
                    .padding()
                    .padding(.trailing, letters == nil ? 0 : 14)
                    .liftMenuHost()
                }
            }
            .remembersScroll(keeper, item: .folders, ids: folders.map(\.id), isFiltered: !search.isEmpty,
                             proxy: proxy, clearSearch: { search = "" })
            .overlay(alignment: .trailing) {
                if let letters {
                    LetterIndex(keys: letters.map(\.key)) { key in
                        if let anchor = letters.first(where: { $0.key == key }) {
                            proxy.scrollTo(anchor.id, anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .overlay {
            if folders.isEmpty && !model.isScanning {
                if search.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder", description: Text("Folders in \(model.libraryName) that hold comics appear here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Folders")
        .searchableWithHistory(text: $search, prompt: "Search folders", list: "folders")
        .toolbar { LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, sortOptions: LibraryGridView.SortOrder.forGroups, sortsByName: true, showTitles: $showTitles) }
        .sheet(isPresented: $showSettings) { SettingsView().toggleStyle(MonoToggleStyle()) }
    }

    private struct LetterAnchor {
        let key: String
        let id: String
    }

    private func letterAnchors(_ folders: [FolderInfo]) -> [LetterAnchor]? {
        guard sort == .title, search.isEmpty, folders.count > 24 else { return nil }
        var seen: Set<String> = []
        var anchors: [LetterAnchor] = []
        for folder in folders {
            let key = IndexKey.of(folder.name)
            if seen.insert(key).inserted { anchors.append(LetterAnchor(key: key, id: folder.id)) }
        }
        return anchors.count > 1 ? anchors : nil
    }
}

/// A folder's cell, which opens the folder. Long-press to pin it to the sidebar.
struct FolderLink: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    let folder: FolderInfo
    var showsPath = false

    var body: some View {
        let item = SidebarItem.folder(folder.path)
        let liftID = "folder:\(folder.path)"
        let model = model
        NavigationLink(value: item) {
            FolderCell(folder: folder, showsPath: showsPath, liftID: liftID)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("folder-\(folder.name)")
        // The cover lifts without the system's grey box around it (#71).
        .liftMenu(id: liftID, menu: { LiftMenuItems.group(item, model: model) }, preview: preview(),
                  cover: { [folder] in folder.coverBookId.flatMap { model.coverNow(for: $0) } })
    }

    /// Draws the folder's cover for the lifted preview, with this tile's settings.
    private func preview() -> @MainActor () -> AnyView {
        let model = model
        let folder = folder
        var style = style
        style.shadowStrength = 0
        let colorScheme = colorScheme
        return {
            AnyView(
                FolderCover(folder: folder, liftID: nil, preloaded: folder.coverBookId.flatMap { model.coverNow(for: $0) })
                    .environment(model)
                    .environment(\.coverStyle, style)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.liftRendering, true)
            )
        }
    }
}

struct FolderCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverStyle) private var style
    /// Read here rather than from the grid, so folder tiles inside a folder's own page follow
    /// the folder browser's Show Titles too.
    @AppStorage(TitleGrid.folders.key) private var showTitles = true
    let folder: FolderInfo
    var showsPath = false
    var liftID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The cover lifts on a long press; the name stays (#71).
            FolderCover(folder: folder, liftID: liftID)
                .modifier(LiftPart(liftID: liftID))
            if showTitles {
                Text(folder.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        if showsPath, folder.path.contains("/") {
            return (folder.path as NSString).deletingLastPathComponent
        }
        var parts = [folder.count == 1 ? "1 book" : "\(folder.count) books"]
        if !folder.children.isEmpty {
            parts.append(folder.children.count == 1 ? "1 folder" : "\(folder.children.count) folders")
        }
        return parts.joined(separator: " · ")
    }
}

/// A folder's cover with its folder badge: the part of its tile that lifts on a long press,
/// drawn both in the grid and into the lifted preview.
struct FolderCover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverStyle) private var style
    @Environment(\.liftRendering) private var rendering
    let folder: FolderInfo
    var liftID: String?
    var preloaded: UIImage?

    var body: some View {
        let cover = folder.coverBookId.flatMap { model.book(id: $0) }
        CoverImage(url: cover.flatMap { model.thumbnails[$0.id] }, title: folder.name,
                   revision: cover.flatMap { model.coverRevision[$0.id] } ?? 0, preloaded: preloaded)
            .overlay(alignment: .topLeading) {
                Image(systemName: "folder.fill")
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .badgeBackground(plain: rendering)
                    .padding(6)
            }
            .modifier(CoverPart(liftID: liftID, cornerRadius: style.cornerRadius))
            .onAppear { if let cover { model.requestCover(for: cover, urgent: true) } }
    }
}
