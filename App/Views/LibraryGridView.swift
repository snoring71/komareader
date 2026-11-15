import LibraryKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    @State private var search = ""
    /// The search text the grid filters by; follows `search` after a short pause in typing.
    @State private var appliedSearch = ""
    @State private var showSettings = false
    @AppStorage("sortOrder") private var sort: SortOrder = .title
    @AppStorage("coverSize") private var coverSize: Double = 150
    /// The size while a pinch is in progress; saved to `coverSize` when it ends.
    @State private var pinchSize: Double?
    @State private var pinchStart: Double?
    /// The books picked in Select mode; nil when not selecting.
    @State private var selection: Set<String>?
    @State private var confirmDeleteAll = false
    @State private var selectionConfirm: SelectionConfirm?

    enum SortOrder: String, CaseIterable, Identifiable {
        case title = "Title", recentlyAdded = "Recently Added", recentlyRead = "Recently Read"
        var id: String { rawValue }
    }

    static let sizeRange: ClosedRange<Double> = 90...300

    private var size: Double { pinchSize ?? coverSize }

    private var visibleBooks: [Book] {
        let search = appliedSearch
        var books = model.books.filter(item.includes)
        if !search.isEmpty {
            books = books.filter { $0.title.localizedStandardContains(search) || $0.folder.localizedStandardContains(search) || $0.series.localizedStandardContains(search) }
        }
        if case .seriesNamed = item {
            return books.sorted(by: SeriesGroup.readingOrder)
        }
        switch sort {
        case .title:
            // The natural-order ranks are worked out once per library change, so this is an integer compare.
            let rank = model.catalog.titleRank
            books.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        case .recentlyAdded: books.sort { $0.addedAt > $1.addedAt }
        case .recentlyRead: books.sort { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        }
        return books
    }

    /// A letter of the index and the first book filed under it, which the index scrolls to.
    struct LetterAnchor {
        let key: String
        let bookId: String
    }

    /// The letters for the index, when sorted by title. The grid itself stays one flat run of
    /// equal cells: a lazy grid split into sections has to guess the height of the sections it
    /// has not drawn yet, and the scroll bar jumped each time a guess was corrected.
    private func letterAnchors(_ books: [Book]) -> [LetterAnchor]? {
        guard sort == .title, appliedSearch.isEmpty, books.count > 24 else { return nil }
        if case .seriesNamed = item { return nil }
        var seen: Set<String> = []
        var anchors: [LetterAnchor] = []
        for book in books {
            let key = model.catalog.indexKey[book.id] ?? IndexKey.of(book.title)
            if seen.insert(key).inserted { anchors.append(LetterAnchor(key: key, bookId: book.id)) }
        }
        return anchors.count > 1 ? anchors : nil
    }

    private var continueReading: [Book] {
        model.books.filter { !$0.isMissing && $0.status == .reading }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: size, maximum: size * 1.35), spacing: 16, alignment: .top)]
    }

    var body: some View {
        let books = visibleBooks
        let letters = letterAnchors(books)
        let continueReading = item == .all && search.isEmpty && selection == nil ? continueReading : []
        ScrollViewReader { proxy in
            ScrollView {
                if !continueReading.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Reading").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(continueReading.prefix(12)) { book in
                                    BookCell(book: book).frame(width: size)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                LazyVGrid(columns: columns, spacing: 22) {
                    // One ForEach for both modes: with an if/else here the lazy grid kept showing
                    // the cells it had already made, and a tap in Select mode opened the book.
                    ForEach(books) { book in
                        BookCell(book: book, isSelected: selection.map { $0.contains(book.id) }) { toggle(book.id) }
                    }
                }
                .padding()
                .padding(.trailing, letters == nil ? 0 : 14) // room for the letter index
            }
            .overlay(alignment: .trailing) {
                if let letters {
                    LetterIndex(keys: letters.map(\.key)) { key in
                        if let anchor = letters.first(where: { $0.key == key }) {
                            proxy.scrollTo(anchor.bookId, anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .simultaneousGesture(pinchGesture)
        .overlay {
            if books.isEmpty && !model.isScanning {
                if !appliedSearch.isEmpty {
                    ContentUnavailableView.search(text: appliedSearch)
                } else if item == .favorites {
                    ContentUnavailableView("No Favorites", systemImage: "heart", description: Text("Books you mark as Favorite appear here."))
                } else if item == .downloaded {
                    ContentUnavailableView("No Downloaded Books", systemImage: "arrow.down.circle", description: Text("Books that are downloaded to this iPad appear here. Long-press a book and choose Download to keep it on this iPad."))
                } else if item == .bookmarked {
                    ContentUnavailableView("No Bookmarked Books", systemImage: "bookmark", description: Text("Books you bookmark appear here."))
                } else {
                    ContentUnavailableView("No Books", systemImage: "books.vertical", description: Text("Comics you add to \(model.libraryName) appear here."))
                }
            }
        }
        .navigationTitle(selectionTitle ?? item.title)
        .searchable(text: $search, prompt: "Search books")
        .task(id: search) {
            // Filtering thousands of books on every keystroke makes typing lag, so wait for a pause.
            if !search.isEmpty, (try? await Task.sleep(for: .milliseconds(200))) == nil { return }
            appliedSearch = search
        }
        .toolbar {
            if let selection {
                SelectionToolbar(item: item, selection: selection, visible: books.map(\.id), setSelection: { self.selection = $0 }, confirm: $selectionConfirm)
            } else {
                LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, showsSort: !isSeriesList) {
                    selection = []
                }
                if item == .missing, !books.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Delete All", role: .destructive) { confirmDeleteAll = true }
                            .accessibilityIdentifier("missing-delete-all")
                    }
                }
            }
        }
        .confirmationDialog(books.count == 1 ? "Delete this book from the library?" : "Delete all \(books.count) missing books from the library?",
                            isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { model.deleteFromLibrary(Set(books.map(\.id))) }
        } message: {
            Text(MissingBooks.deleteMessage)
        }
        .confirmationDialog(selectionConfirm?.title(count: selection?.count ?? 0) ?? "",
                            isPresented: Binding(get: { selectionConfirm != nil }, set: { if !$0 { selectionConfirm = nil } }),
                            titleVisibility: .visible, presenting: selectionConfirm) { kind in
            let ids = selection ?? []
            switch kind {
            case .delete:
                Button("Delete from Library", role: .destructive) {
                    model.deleteFromLibrary(ids)
                    selection = nil
                }
            case .regenerate:
                Button("Regenerate Covers", role: .destructive) {
                    Task { await model.regenerateCovers(ids) }
                    selection = nil
                }
            }
        } message: { kind in
            Text(kind.message)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var selectionTitle: String? {
        guard let selection else { return nil }
        return selection.isEmpty ? "Select Books" : selection.count == 1 ? "1 Book Selected" : "\(selection.count) Books Selected"
    }

    private func toggle(_ id: String) {
        guard var current = selection else { return }
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        selection = current
    }

    private var isSeriesList: Bool {
        if case .seriesNamed = item { return true }
        return false
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.04)
            .onChanged { value in
                let start = pinchStart ?? coverSize
                pinchStart = start
                pinchSize = min(max(start * value.magnification, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            }
            .onEnded { _ in
                if let pinchSize { coverSize = pinchSize }
                pinchSize = nil
                pinchStart = nil
            }
    }
}

/// The library's toolbar menu: sort, cover size, rescan, settings.
struct LibraryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var sort: LibraryGridView.SortOrder
    @Binding var coverSize: Double
    @Binding var showSettings: Bool
    var showsSort = true
    /// Starts Select mode; nil where books cannot be selected.
    var onSelect: (() -> Void)?
    var coverInfo = CoverInfoSettings()

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Tap to show or hide the info on the covers; hold to choose what it shows.
            Menu {
                Toggle("Show Info on Covers", systemImage: "info.circle", isOn: coverInfo.$isOn)
                Section("Show") {
                    CoverInfoFieldControls()
                }
            } label: {
                Label("Cover Info", systemImage: coverInfo.isOn ? "info.circle.fill" : "info.circle")
            } primaryAction: {
                coverInfo.isOn.toggle()
            }
            .menuActionDismissBehavior(.disabled)
            .accessibilityIdentifier("library-cover-info")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let onSelect {
                    Button("Select", systemImage: "checkmark.circle") { onSelect() }
                        .accessibilityIdentifier("library-select")
                }
                if showsSort {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibraryGridView.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Cover Size (or pinch the grid)") {
                    Button("Larger", systemImage: "plus.magnifyingglass") { coverSize = min(LibraryGridView.sizeRange.upperBound, coverSize + 30) }
                    Button("Smaller", systemImage: "minus.magnifyingglass") { coverSize = max(LibraryGridView.sizeRange.lowerBound, coverSize - 30) }
                }
                Section {
                    Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await model.rescan() } }
                    Button("Settings…", systemImage: "gear") { showSettings = true }
                }
            } label: {
                Label("Options", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("library-options")
        }
        // Top bar, not `.status`: a status item sits in the bottom bar and pushes the Resume button around.
        if model.isScanning {
            ToolbarItem(placement: .topBarTrailing) { ProgressView() }
        }
    }
}

/// The A–Z strip on the right edge. Tap or slide along it to jump to a letter.
struct LetterIndex: View {
    let keys: [String]
    let onSelect: (String) -> Void
    @State private var current: String?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 18, height: rowHeight(in: geo.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let total = rowHeight(in: geo.size.height) * CGFloat(keys.count)
                        let top = (geo.size.height - total) / 2
                        let row = Int((value.location.y - top) / max(rowHeight(in: geo.size.height), 1))
                        let key = keys[min(max(row, 0), keys.count - 1)]
                        if key != current {
                            current = key
                            onSelect(key)
                        }
                    }
                    .onEnded { _ in current = nil }
            )
            .sensoryFeedback(.selection, trigger: current)
        }
        .frame(width: 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Letter index")
        .accessibilityIdentifier("letter-index")
    }

    private func rowHeight(in height: CGFloat) -> CGFloat {
        min(18, height / CGFloat(max(keys.count, 1)))
    }
}

/// Series as stacks of covers; each opens a grid of that series' books in volume order.
struct SeriesGridView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var showSettings = false
    @AppStorage("sortOrder") private var sort: LibraryGridView.SortOrder = .title
    @AppStorage("coverSize") private var coverSize: Double = 150

    var body: some View {
        let groups = model.catalog.series.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 20, alignment: .top)], spacing: 24) {
                ForEach(groups) { group in
                    NavigationLink(value: SidebarItem.seriesNamed(group.name)) {
                        SeriesCell(group: group)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("series-\(group.name)")
                }
            }
            .padding()
        }
        .overlay {
            if groups.isEmpty && !model.isScanning {
                if search.isEmpty {
                    ContentUnavailableView("No Series", systemImage: "square.stack")
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle("Series")
        .searchable(text: $search, prompt: "Search series")
        .toolbar { LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, showsSort: false) }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct SeriesCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverStyle) private var style
    let group: SeriesGroup

    var body: some View {
        let cover = group.books.first
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // A hint of the volumes behind the first one.
                if group.books.count > 1 {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(Color(.systemGray3))
                        .aspectRatio(style.shape.aspect, contentMode: .fit)
                        .scaleEffect(0.92)
                        .offset(y: -10)
                }
                CoverImage(url: cover.flatMap { model.thumbnails[$0.id] }, title: group.name,
                           revision: cover.flatMap { model.coverRevision[$0.id] } ?? 0)
            }
            .padding(.top, group.books.count > 1 ? 10 : 0)
            .onAppear { if let cover { model.requestCover(for: cover, urgent: true) } }
            Text(group.name)
                .font(.footnote.weight(.medium))
                .lineLimit(2, reservesSpace: true)
            Text(group.books.count == 1 ? "1 book" : "\(group.books.count) books")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct BookCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverInfo) private var info
    let book: Book
    /// Set in Select mode: whether the book is picked. A tap then picks or unpicks it.
    var isSelected: Bool?
    var onSelect: (() -> Void)?
    @State private var confirmDelete = false

    var body: some View {
        Button {
            if isSelected != nil {
                onSelect?()
            } else {
                Task { await model.activate(book) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: model.thumbnails[book.id], title: book.title, revision: model.coverRevision[book.id] ?? 0)
                    .overlay(alignment: .topTrailing) { badge }
                    .overlay(alignment: .bottom) {
                        if info.isOn {
                            CoverInfoOverlay(book: book, status: overlayStatus)
                        } else {
                            progressBar
                        }
                    }
                    .overlay(alignment: .topLeading) { selectionMark }
                if !info.isOn {
                    // Every cell keeps room for two title lines, so all rows are the same height and the
                    // scroll bar does not jump as rows of different heights come into view.
                    Text(book.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2, reservesSpace: true)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        if book.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                        if book.bookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                        Text(statusText).foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .imageScale(.small)
                }
            }
            // The whole cell is the tap target, and nothing outside it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("book-\(book.title)")
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .onAppear { model.requestCover(for: book, urgent: true) }
        .contextMenu {
            if isSelected == nil { menu }
        }
        .confirmationDialog("Delete this book from the library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) { model.deleteFromLibrary([book.id]) }
        } message: {
            Text(MissingBooks.deleteMessage)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Book Info", systemImage: "info.circle") { model.bookInfo = .init(id: book.id) }
        if book.isMissing {
            // The file is gone: all that is left to do is to delete what the app kept of it.
            Button("Delete from Library", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } else {
            Button("Edit Cover…", systemImage: "crop") { Task { await model.editCover(book) } }
            Button("Regenerate Cover", systemImage: "arrow.triangle.2.circlepath") { Task { await model.regenerateCover(book) } }
            Section {
                Button(book.favorite ? "Remove from Favorites" : "Favorite", systemImage: book.favorite ? "heart.slash" : "heart") {
                    model.setFavorite(book, !book.favorite)
                }
                Button(book.bookmarked ? "Remove Bookmark" : "Bookmark", systemImage: book.bookmarked ? "bookmark.slash" : "bookmark") {
                    model.setBookmarked(book, !book.bookmarked)
                }
            }
            if book.isDownloaded {
                Button("Remove from iPad", systemImage: "icloud.and.arrow.up") { model.removeDownload(book) }
            } else {
                Button("Download", systemImage: "icloud.and.arrow.down") { Task { await model.download(book) } }
            }
            if book.status == .read {
                Button("Mark as Unread", systemImage: "circle") { model.setFinished(book, false) }
            } else {
                Button("Mark as Read", systemImage: "checkmark.circle") { model.setFinished(book, true) }
            }
        }
    }

    private var downloadStatus: String? {
        if model.downloading.contains(book.id) { return "Downloading…" }
        if model.queuedDownloads.contains(book.id) { return "Waiting to Download" }
        return nil
    }

    private var statusText: String {
        if let downloadStatus { return downloadStatus }
        switch book.status {
        case .read: return "Read"
        case .reading: return book.progressFraction.map { "\(Int($0 * 100))%" } ?? "Reading"
        case .unread: return book.format.displayName
        }
    }

    /// The overlay shows the format itself when asked to, so it leaves "unread" out.
    private var overlayStatus: String? {
        if let downloadStatus { return downloadStatus }
        switch book.status {
        case .read: return "Read"
        case .reading: return book.progressFraction.map { "\(Int($0 * 100))%" } ?? "Reading"
        case .unread: return nil
        }
    }

    @ViewBuilder private var selectionMark: some View {
        if let isSelected {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.black.opacity(0.25)))
                .shadow(color: .black.opacity(0.35), radius: 2)
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var badge: some View {
        if model.downloading.contains(book.id) {
            ProgressView().padding(6).glassEffect(in: .circle).padding(6)
        } else if !book.isDownloaded {
            Image(systemName: model.queuedDownloads.contains(book.id) ? "icloud.and.arrow.down" : "icloud")
                .font(.caption.weight(.semibold))
                .padding(6)
                .glassEffect(in: .circle)
                .padding(6)
        } else if book.status == .read {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .padding(6)
        }
    }

    @ViewBuilder private var progressBar: some View {
        if book.status == .reading, let fraction = book.progressFraction {
            GeometryReader { geo in
                Capsule().fill(.black.opacity(0.35))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.tint).frame(width: geo.size.width * fraction)
                    }
            }
            .frame(height: 4)
            .padding(8)
        }
    }
}

/// Actions in Select mode that ask first.
enum SelectionConfirm: Identifiable {
    case delete, regenerate
    var id: Self { self }

    func title(count: Int) -> String {
        switch self {
        case .delete: return count == 1 ? "Delete this book from the library?" : "Delete \(count) books from the library?"
        case .regenerate: return count == 1 ? "Regenerate this cover?" : "Regenerate \(count) covers?"
        }
    }

    var message: String {
        switch self {
        case .delete: return MissingBooks.deleteMessage
        case .regenerate: return "Edited covers are removed on all your devices, and new covers are made from the first pages. Books only in iCloud are downloaded for a moment to make them."
        }
    }
}

enum MissingBooks {
    static let deleteMessage = "The file is already gone. This removes the book's reading progress, cover and other details from Comic Reader on all your devices. If the file comes back, it shows up as a new book."
}

/// The toolbar in Select mode: the actions for the picked books, Select All and Done.
struct SelectionToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let selection: Set<String>
    /// The books on screen, which Select All picks.
    let visible: [String]
    /// Changes the selection; nil ends Select mode.
    let setSelection: (Set<String>?) -> Void
    /// Set to ask before an action that cannot be undone; the grid shows the question.
    @Binding var confirm: SelectionConfirm?

    private var picked: [Book] {
        model.books.filter { selection.contains($0.id) }
    }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                actions
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .disabled(selection.isEmpty)
            .accessibilityIdentifier("selection-actions")
        }
        ToolbarItem(placement: .primaryAction) {
            let all = !visible.isEmpty && visible.allSatisfy(selection.contains)
            Button(all ? "Deselect All" : "Select All") {
                setSelection(all ? [] : Set(visible))
            }
            .accessibilityIdentifier("selection-all")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { setSelection(nil) }
                .accessibilityIdentifier("selection-done")
        }
    }

    /// Runs an action on the picked books, then leaves Select mode.
    private func finish(_ action: () -> Void) {
        action()
        setSelection(nil)
    }

    @ViewBuilder private var actions: some View {
        let ids = selection
        if item == .missing {
            Button("Delete from Library", systemImage: "trash", role: .destructive) { confirm = .delete }
        } else {
            let books = picked
            let allFavorite = books.allSatisfy(\.favorite)
            let allBookmarked = books.allSatisfy(\.bookmarked)
            let allRead = books.allSatisfy { $0.status == .read }
            Section {
                Button(allFavorite ? "Remove from Favorites" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart") {
                    finish { model.setFavorite(ids, !allFavorite) }
                }
                Button(allBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: allBookmarked ? "bookmark.slash" : "bookmark") {
                    finish { model.setBookmarked(ids, !allBookmarked) }
                }
            }
            Section {
                if allRead {
                    Button("Mark as Unread", systemImage: "circle") { finish { model.setFinished(ids, false) } }
                } else {
                    Button("Mark as Read", systemImage: "checkmark.circle") { finish { model.setFinished(ids, true) } }
                    if books.contains(where: { $0.status != .unread }) {
                        Button("Mark as Unread", systemImage: "circle") { finish { model.setFinished(ids, false) } }
                    }
                }
            }
            Menu("Reading Direction", systemImage: "arrow.left.arrow.right") {
                Button("Left to Right") { finish { model.setDirection(ids, .leftToRight) } }
                Button("Right to Left (Manga)") { finish { model.setDirection(ids, .rightToLeft) } }
            }
            Section {
                if books.contains(where: { !$0.isDownloaded }) {
                    Button("Download", systemImage: "icloud.and.arrow.down") { finish { model.download(ids) } }
                }
                if books.contains(where: \.isDownloaded) {
                    Button("Remove from iPad", systemImage: "icloud.and.arrow.up") { finish { model.removeDownloads(ids) } }
                }
            }
            Section {
                Button("Regenerate Covers", systemImage: "arrow.triangle.2.circlepath") { confirm = .regenerate }
            }
        }
    }
}

/// A cover thumbnail, decoded off the main thread, with a placeholder until it is ready.
struct CoverImage: View {
    let url: URL?
    let title: String
    /// Changes when the cover file is replaced at the same URL (after a cover edit).
    var revision: Int = 0
    @Environment(\.coverStyle) private var style
    @State private var loaded: UIImage?

    private struct Key: Equatable { let url: URL?; let revision: Int }

    var body: some View {
        // A cover seen before is shown at once from memory, with no placeholder in between.
        let image = loaded ?? url.flatMap { CoverMemoryCache.shared.image(for: $0, revision: revision) }
        // Opaque, so the shadow behind it does not show through the placeholder.
        Color(.systemGray5)
            .aspectRatio(style.shape.aspect, contentMode: .fit)
            .overlay {
                if let image {
                    // A wide cover is cropped to the cell, and must not take taps outside it either.
                    Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
                } else {
                    Text(title)
                        .font(.caption.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .background { CoverShadow(strength: style.shadowStrength, direction: style.shadowDirection, cornerRadius: style.cornerRadius) }
            .task(id: Key(url: url, revision: revision)) {
                guard let url else { loaded = nil; return }
                let revision = revision
                if let cached = CoverMemoryCache.shared.image(for: url, revision: revision) {
                    loaded = cached
                    return
                }
                loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
                    CoverMemoryCache.shared.insert(image, for: url, revision: revision)
                    return image
                }.value
            }
    }
}

/// Decoded grid covers kept in memory, so scrolling back shows them at once instead of
/// reading and decoding each file again. The system empties it if memory runs short.
final class CoverMemoryCache: @unchecked Sendable {
    static let shared = CoverMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // About 450 KB per cover: room for roughly 1,000 of them on devices with 6 GB or more.
        let memory = ProcessInfo.processInfo.physicalMemory
        cache.totalCostLimit = memory >= 6_000_000_000 ? 480 * 1024 * 1024 : 200 * 1024 * 1024
    }

    private func key(_ url: URL, _ revision: Int) -> NSString { "\(url.path)#\(revision)" as NSString }

    func image(for url: URL, revision: Int) -> UIImage? {
        cache.object(forKey: key(url, revision))
    }

    func insert(_ image: UIImage, for url: URL, revision: Int) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key(url, revision), cost: cost)
    }
}
