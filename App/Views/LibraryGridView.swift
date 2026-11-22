import ComicCore
import LibraryKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    @State private var search = ""
    /// The search text the grid filters by; follows `search` after a short pause in typing.
    @State private var appliedSearch = ""
    @State private var showSettings = false
    /// The sort, kept for each list (All Books, a folder, a series, a tag…, #79).
    @AppStorage private var sort: SortOrder
    /// "asc" or "desc"; empty is the order's own direction.
    @AppStorage private var sortDirection: String
    @AppStorage("coverSize") private var coverSize: Double = 150
    @AppStorage(TitleGrid.books.key) private var showTitles = true
    /// The size while a pinch is in progress; saved to `coverSize` when it ends.
    @State private var pinchSize: Double?
    @State private var pinchStart: Double?
    @State private var visible = VisibleBooks()
    /// The books picked in Select mode; nil when not selecting.
    @State private var selection: Set<String>?
    @State private var confirmDeleteAll = false
    @State private var selectionConfirm: SelectionConfirm?
    @State private var reordering = false
    /// The filter bar's filter (#80): kept while the app runs, cleared with another sidebar row.
    @State private var filter = LibraryFilter()
    @State private var showFilter = false
    @Environment(\.coverInfo) private var coverInfo
    /// The first book on screen and whether the grid is scrolled down, so turning Cover Info
    /// on or off (which changes the height of every cell) keeps the same books in view.
    /// Kept in a plain object, not in view state: it changes on every row scrolled past, and
    /// redrawing the grid each time would sort the whole library again.
    @State private var scrollSpot = ScrollSpot()
    /// Keeps this view's place for the session, for coming back to it (#105).
    @State private var keeper = ScrollKeeper()

    final class ScrollSpot {
        var firstVisible: String?
        var scrolledDown = false
    }

    init(item: SidebarItem) {
        self.item = item
        // Lists sorted before sorts were kept per list start from the one sort there was.
        let shared = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .title
        var fallback = shared
        if case .readingList = item { fallback = .listOrder }
        _sort = AppStorage(wrappedValue: fallback, "sortOrder." + item.storageKey)
        _sortDirection = AppStorage(wrappedValue: "", "sortDirection." + item.storageKey)
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case title = "Title", author = "Author", releaseYear = "Release Year"
        case recentlyAdded = "Recently Added", recentlyRead = "Recently Read", dateFinished = "Date Finished"
        case fileSize = "File Size", pageCount = "Page Count", rating = "Rating"
        /// A reading list's own order (#83).
        case listOrder = "List Order"
        var id: String { rawValue }

        /// The menu's word for it. Folders and series have names, not titles (#99, #100); the
        /// saved value stays "Title".
        func label(byName: Bool) -> String {
            self == .title && byName ? "Name" : rawValue
        }

        /// The direction the order goes in unless the user turns it round: A to Z, oldest year
        /// first, newest date first, biggest first, best rated first.
        var ascendingByDefault: Bool {
            switch self {
            case .title, .author, .releaseYear, .listOrder: return true
            case .recentlyAdded, .recentlyRead, .dateFinished, .fileSize, .pageCount, .rating: return false
            }
        }

        /// The letter index shows for orders by name.
        var hasLetterIndex: Bool { self == .title || self == .author }

        static let forBooks: [SortOrder] = [.title, .author, .releaseYear, .recentlyAdded, .recentlyRead, .dateFinished, .fileSize, .pageCount, .rating]
        static let forLists: [SortOrder] = [.listOrder] + forBooks
        /// Folders, series, authors and publishers.
        static let forGroups: [SortOrder] = [.title, .recentlyAdded, .recentlyRead]
    }

    private var ascending: Bool {
        switch sortDirection {
        case "asc": return true
        case "desc": return false
        default: return sort.ascendingByDefault
        }
    }

    private var sortOptions: [SortOrder] {
        if case .readingList = item { return SortOrder.forLists }
        return SortOrder.forBooks
    }

    static let sizeRange: ClosedRange<Double> = 90...300

    private var size: Double { pinchSize ?? coverSize }

    /// The filtered and sorted books, kept until something they depend on changes. The body
    /// runs again for much else (each frame of a pinch, each tap in Select mode, a dialog),
    /// and filtering and sorting the whole library each time made those slow in a big one.
    @State private var visibleCache = VisibleCache()

    final class VisibleCache {
        struct Key: Equatable {
            let item: SidebarItem
            let booksVersion: Int
            let searchKeysRevision: Int
            let lists: LibraryLists
            let upNext: [String]
            let search: String
            let filter: LibraryFilter
            let sort: SortOrder
            let ascending: Bool
            /// Filters like "read in the last 7 days" move on with the date.
            let day: Date
        }
        var key: Key?
        var books: [Book] = []
    }

    private var visibleBooks: [Book] {
        // Read every time, so the grid still redraws when any of these change.
        let key = VisibleCache.Key(item: item, booksVersion: model.booksVersion, searchKeysRevision: model.searchKeysRevision,
                                   lists: model.lists, upNext: model.upNext, search: appliedSearch, filter: filter,
                                   sort: sort, ascending: ascending, day: Calendar.current.startOfDay(for: Date()))
        if visibleCache.key == key { return visibleCache.books }
        let books = computeVisibleBooks()
        visibleCache.key = key
        visibleCache.books = books
        return books
    }

    private func computeVisibleBooks() -> [Book] {
        // A typed search may hold field prefixes (#81); it and the filter bar are one filter.
        let active = filter.combined(with: LibraryFilter.parse(appliedSearch))
        var books = baseBooks
        if !active.isEmpty {
            // Kana, kanji and romaji all find Japanese titles (#106).
            _ = model.searchKeysRevision
            let now = Date()
            let text = model.textMatcher(active.text)
            books = books.filter { active.matches($0, now: now, matchesText: text) }
        }
        if item == .upNext { return books }
        if case .smartList(let id) = item, model.lists.list(id)?.sort != nil { return books }
        if case .seriesNamed = item {
            return books.sorted(by: SeriesGroup.readingOrder)
        }
        if item == .continueReading {
            // The book read last comes first, whatever the sort menu says.
            return books.sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        }
        return Self.sorted(books, by: sort, ascending: ascending, model: model)
    }

    /// The books in this list before search and sorting. A reading list keeps its own order
    /// and its missing books (#83).
    private var baseBooks: [Book] {
        switch item {
        case .readingList(let id): return model.listBooks(id)
        case .smartList(let id): return model.smartListBooks(id, fallback: (sort, ascending))
        case .upNext: return model.upNext.compactMap { model.book(id: $0) }
        default: return model.books.filter(item.includes)
        }
    }

    /// Books in a sort order (#79). Books without the value sorted by go last either way, in
    /// title order; ties are in title order too.
    static func sorted(_ books: [Book], by sort: SortOrder, ascending: Bool, model: AppModel) -> [Book] {
        // The natural-order ranks are worked out once per library change, so ties and title
        // order are integer compares.
        let rank = model.catalog.titleRank
        func byTitle(_ a: Book, _ b: Book) -> Bool { (rank[a.id] ?? .max) < (rank[b.id] ?? .max) }
        func by<T: Comparable>(_ value: (Book) -> T?) -> [Book] {
            let keyed = books.map { (book: $0, key: value($0)) }
            return keyed.sorted { a, b in
                switch (a.key, b.key) {
                case let (x?, y?): return x == y ? byTitle(a.book, b.book) : (ascending ? x < y : x > y)
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return byTitle(a.book, b.book)
                }
            }.map(\.book)
        }
        switch sort {
        case .title:
            let ordered = books.sorted(by: byTitle)
            return ascending ? ordered : ordered.reversed()
        case .listOrder:
            return ascending ? books : books.reversed()
        case .author:
            // By the first author's name in natural order, then by series and volume.
            let keys = Dictionary(books.compactMap { book in book.authors.first.map { (book.id, NaturalSortKey($0)) } }, uniquingKeysWith: { a, _ in a })
            let keyed = books.map { (book: $0, key: keys[$0.id]) }
            return keyed.sorted { a, b in
                switch (a.key, b.key) {
                case let (x?, y?):
                    if x == y { return SeriesGroup.bySeries(a.book, b.book) }
                    return ascending ? x < y : y < x
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return byTitle(a.book, b.book)
                }
            }.map(\.book)
        case .releaseYear:
            // Year, then month and day where known.
            return by { book in book.info.year.map { $0 * 10_000 + (book.info.month ?? 0) * 100 + (book.info.day ?? 0) } }
        case .recentlyAdded: return by { $0.addedAt }
        case .recentlyRead: return by { $0.lastReadAt }
        case .dateFinished: return by { $0.finished ? $0.lastReadAt : nil }
        case .fileSize: return by { $0.size }
        case .pageCount: return by { $0.pageCount }
        case .rating: return by { $0.rating }
        }
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
        guard sort.hasLetterIndex, appliedSearch.isEmpty, books.count > 24, showsSort else { return nil }
        var seen: Set<String> = []
        var anchors: [LetterAnchor] = []
        for book in books {
            let key = sort == .author
                ? (book.authors.first.map(IndexKey.of) ?? "#")
                : (model.catalog.indexKey[book.id] ?? IndexKey.of(book.title))
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

    /// Subfolders, shown above a folder's own books.
    private var subfolders: [FolderInfo] {
        guard case .folder(let path) = item, appliedSearch.isEmpty, let folder = model.catalog.folders[path] else { return [] }
        return folder.children.compactMap { model.catalog.folders[$0] }
    }

    var body: some View {
        let books = visibleBooks
        let letters = letterAnchors(books)
        let continueReading = item == .all && search.isEmpty && filter.isEmpty ? continueReading : []
        // The next unread volume of each series in progress; ones part-way through are
        // already in Continue Reading (#85).
        let upNext = item == .all && search.isEmpty && filter.isEmpty
            ? model.upNext.compactMap { model.book(id: $0) }.filter { $0.status == .unread } : []
        let subfolders = subfolders
        let listKey = item.storageKey
        let _ = (visible.books = books)
        let _ = (visible.listName = { if case .readingList = item { return item.title } else { return nil } }())
        ScrollViewReader { proxy in
            ScrollView {
              // Explicit spacing, so the gaps below are exactly what they say.
              VStack(alignment: .leading, spacing: 0) {
                ScrollTopMarker()
                if !continueReading.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Continue Reading").font(.title3.bold())
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(continueReading.prefix(12)) { book in
                                    // Selectable here too, so Select mode leaves the page where it is.
                                    BookCell(book: book, isSelected: selection.map { $0.contains(book.id) }, place: "continue") { toggle(book.id) }
                                        .frame(width: size)
                                        // Always the plain look, so the row keeps its height and
                                        // the page does not jump when Cover Info is turned on or off.
                                        .environment(\.coverInfo, CoverInfo())
                                        // Its own id, so scrolling to a book finds it in the grid below.
                                        .id("continue-\(book.id)")
                                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                                }
                            }
                            // A book that leaves (marked unread or read) fades out, and the
                            // others slide over into its place instead of jumping.
                            .animation(.snappy(duration: 0.4), value: continueReading.prefix(12).map(\.id))
                            // Room under the covers for their shadows. Without titles the cover is
                            // the last thing in the cell, and the scroll view clipped its bottom.
                            .padding(.bottom, 14)
                        }
                        // Full width, with the usual 16 pt inset as a content margin, so the fade
                        // below can reach the screen edge where the letter index sits (#65).
                        .contentMargins(.leading, 16, for: .scrollContent)
                        .contentMargins(.trailing, letters == nil ? 16 : EdgeFade.trailingRoom, for: .scrollContent)
                        .scrollClipDisabled()
                        .modifier(EdgeFade(isOn: letters != nil))
                    }
                    .padding(.top, 8)

                }
                if !upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Up Next").font(.title3.bold())
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(upNext.prefix(12)) { book in
                                    BookCell(book: book, isSelected: selection.map { $0.contains(book.id) }, place: "upnext") { toggle(book.id) }
                                        .frame(width: size)
                                        .environment(\.coverInfo, CoverInfo())
                                        .id("upnext-\(book.id)")
                                }
                            }
                            .padding(.bottom, 14)
                        }
                        .contentMargins(.leading, 16, for: .scrollContent)
                        .contentMargins(.trailing, letters == nil ? 16 : EdgeFade.trailingRoom, for: .scrollContent)
                        .scrollClipDisabled()
                        .modifier(EdgeFade(isOn: letters != nil))
                    }
                    .padding(.top, continueReading.isEmpty ? 8 : 18)
                }
                if !continueReading.isEmpty || !upNext.isEmpty {
                    // Where the full list starts (#58). Plain views above the grid, not a
                    // section in it, so the grid stays one flat run of equal cells.
                    VStack(alignment: .leading, spacing: 0) {
                        SoftDivider()
                            .padding(.top, 12)
                        Text("All Books")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, 22)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                if !subfolders.isEmpty {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(subfolders) { FolderLink(folder: $0) }
                    }
                    .padding([.horizontal, .top])
                    .padding(.trailing, letters == nil ? 0 : 14)
                    if !books.isEmpty { Divider().padding(.horizontal).padding(.top, 8) }
                }

                LazyVGrid(columns: columns, spacing: 22) {
                    // One ForEach for both modes: with an if/else here the lazy grid kept showing
                    // the cells it had already made, and a tap in Select mode opened the book.
                    ForEach(books) { book in
                        BookCell(book: book, isSelected: selection.map { $0.contains(book.id) }) { toggle(book.id) }
                            // The grid's order, for what the book's last page offers next (#83).
                            .environment(\.gridOrder, visible)
                            // A reading list keeps a book whose file went missing, dimmed (#83).
                            .opacity(isList && book.isMissing ? 0.4 : 1)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                }
                // In Continue Reading, a book that leaves fades out and the others slide into
                // place. Only there: animating the whole library on every change would be slow.
                .animation(item == .continueReading ? .snappy(duration: 0.4) : nil,
                           value: item == .continueReading ? books.map(\.id) : [])
                .scrollTargetLayout()
                .padding(.horizontal)
                .padding(.bottom)
                // Under the All Books heading, the same 10 pt gap as under Continue Reading's.
                .padding(.top, continueReading.isEmpty && upNext.isEmpty ? 16 : 10)
                .padding(.trailing, letters == nil ? 0 : 14) // room for the letter index
              }
              // Long-press menus for every tile on the page, Continue Reading included (#71).
              .liftMenuHost()
            }
            .environment(\.showTitles, showTitles)
            .environment(\.libraryIconSize, LibraryIconSize.forCover(width: size))
            // Back where the user left off in this view earlier in the session, or at the
            // last launch (#105).
            // A search that starts with whole text at once (a past search picked, or text
            // pasted) has the full list on screen, scrolled to its top, until the results are
            // worked out. Hidden for that moment, as elsewhere, so only the results show.
            .opacity(!search.isEmpty && appliedSearch.isEmpty ? 0 : 1)
            .remembersScroll(keeper, item: item, ids: books.map(\.id),
                             isFiltered: !search.isEmpty || !appliedSearch.isEmpty, proxy: proxy,
                             clearSearch: { search = ""; appliedSearch = "" }) { ids in
                visible.ids = visible.inGridOrder(ids)
                scrollSpot.firstVisible = visible.ids.first
                if let top = visible.ids.first { LibraryPosition.noteTopBook(.init(list: listKey, bookId: top)) }
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 60
            } action: { _, down in
                scrollSpot.scrolledDown = down
            }
            .onChange(of: coverInfo.isOn) { keepPlace(proxy) }
            .onChange(of: showTitles) { keepPlace(proxy) }
            .onChange(of: size) { _, _ in
                // Keep the books that were on screen in view as the columns change.
                guard let id = visible.zoomAnchor ?? visible.middle else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
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
            if books.isEmpty && subfolders.isEmpty && !model.isScanning {
                if !appliedSearch.isEmpty {
                    ContentUnavailableView.search(text: appliedSearch)
                } else if item == .favorites {
                    ContentUnavailableView("No Favorites", systemImage: "heart", description: Text("Books you mark as Favorite appear here."))
                } else if item == .downloaded {
                    ContentUnavailableView("No Downloaded Books", systemImage: "arrow.down.circle", description: Text("Books that are downloaded to this iPad appear here. Long-press a book and choose Download to keep it on this iPad."))
                } else if case .tag(let name) = item {
                    ContentUnavailableView("No Books Tagged “\(name)”", systemImage: "tag", description: Text("Long-press a book and choose Tags… to add this tag. The tag stays until you delete it from the sidebar."))
                } else if case .readingList = item {
                    ContentUnavailableView("No Books in This List", systemImage: "list.number", description: Text("Long-press a book and choose Add to Reading List…, or select several books and add them from the Actions menu."))
                } else if item == .bookmarked {
                    ContentUnavailableView("No Bookmarked Books", systemImage: "bookmark", description: Text("Books with a bookmarked page appear here. To bookmark a page, tap the bookmark button in the reader."))
                } else {
                    ContentUnavailableView("No Books", systemImage: "books.vertical", description: Text("Comics you add to \(model.libraryName) appear here."))
                }
            }
        }
        .navigationTitle(selectionTitle ?? item.title)
        // The active filters as chips (#80), and typed field searches (#81).
        .safeAreaInset(edge: .top, spacing: 0) {
            let typed = LibraryFilter.parse(appliedSearch)
            if !filter.isEmpty || !typed.isEmpty {
                FilterChips(filter: $filter, typed: typed) {
                    model.smartEditor = .init(listId: nil, filter: filter.combined(with: typed))
                }
                .background(.bar)
            }
        }
        .searchableWithHistory(text: $search, prompt: "Search books", list: "books")
        .searchSuggestions { SearchFieldSuggestions(search: $search) }
        .task(id: search) {
            // Filtering thousands of books on every keystroke makes typing lag, so wait for a pause.
            // Not before the first results, though: the grid is hidden until they are in.
            if !search.isEmpty, !appliedSearch.isEmpty, (try? await Task.sleep(for: .milliseconds(200))) == nil { return }
            appliedSearch = search
        }
        .toolbar {
            if let selection {
                SelectionToolbar(item: item, selection: selection, visible: books.map(\.id), setSelection: { self.selection = $0 }, confirm: $selectionConfirm)
            } else {
                LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, showsSort: showsSort,
                               sortOptions: sortOptions, sortAscending: Binding(
                                   get: { ascending },
                                   set: { sortDirection = $0 == sort.ascendingByDefault ? "" : ($0 ? "asc" : "desc") }),
                               showTitles: $showTitles) {
                    selection = []
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilter = true
                    } label: {
                        Label("Filter", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("library-filter")
                    .popover(isPresented: $showFilter) { FilterPanel(filter: $filter) }
                }
                if case .readingList = item, !books.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reorder…", systemImage: "arrow.up.arrow.down") { reordering = true }
                            .accessibilityIdentifier("list-reorder")
                    }
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
        .sheet(isPresented: $showSettings) { SettingsView().toggleStyle(MonoToggleStyle()) }
        .sheet(isPresented: $reordering) {
            if case .readingList(let id) = item { ReadingListOrderView(listId: id) }
        }
    }

    /// After a change to the height of every cell (Cover Info, Show Titles), scrolls back to
    /// the book that was first on screen. At the top, Continue Reading and the first rows stay
    /// put on their own.
    private func keepPlace(_ proxy: ScrollViewProxy) {
        guard scrollSpot.scrolledDown, let id = scrollSpot.firstVisible else { return }
        Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
    }

    private var isList: Bool {
        if case .readingList = item { return true }
        return false
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

    /// Series list in volume order and Continue Reading by last read, so no sort menu.
    private var showsSort: Bool {
        if case .seriesNamed = item { return false }
        // A smart list with its own sort keeps it (#82).
        if case .smartList(let id) = item, model.lists.list(id)?.sort != nil { return false }
        return item != .continueReading && item != .upNext
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.04)
            .onChanged { value in
                let start = pinchStart ?? coverSize
                if pinchStart == nil { visible.zoomAnchor = visible.middle }
                pinchStart = start
                pinchSize = min(max(start * value.magnification, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
            }
            .onEnded { _ in
                if let pinchSize { coverSize = pinchSize }
                pinchSize = nil
                pinchStart = nil
                visible.zoomAnchor = nil
            }
    }
}

/// The books on screen, kept outside SwiftUI's state so scrolling does not redraw the grid.
@MainActor
extension EnvironmentValues {
    /// The grid a book cell is in (#83); nil in the Continue Reading and Up Next rows.
    @Entry var gridOrder: VisibleBooks?
}

final class VisibleBooks {
    /// Set on a reading list's grid, for the reader's "Next in …" (#83).
    var listName: String?
    /// Visible book ids, in grid order.
    var ids: [String] = []
    /// The book to keep in view during a pinch.
    var zoomAnchor: String?
    var books: [Book] = [] { didSet { order = nil } }
    private var order: [String: Int]?

    var middle: String? { ids.isEmpty ? nil : ids[ids.count / 2] }

    func inGridOrder(_ ids: [String]) -> [String] {
        if order == nil {
            var order: [String: Int] = [:]
            order.reserveCapacity(books.count)
            for (i, book) in books.enumerated() { order[book.id] = i }
            self.order = order
        }
        guard let order else { return ids }
        return ids.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }
}

/// The library's toolbar menu: sort, cover size, rescan, settings.
struct LibraryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Binding var sort: LibraryGridView.SortOrder
    @Binding var coverSize: Double
    @Binding var showSettings: Bool
    var showsSort = true
    /// The orders the Sort By menu offers.
    var sortOptions = LibraryGridView.SortOrder.forGroups
    /// Ascending or descending (#79); nil where the list has no such choice.
    var sortAscending: Binding<Bool>?
    /// Sort By says Name rather than Title (folders, series).
    var sortsByName = false
    /// The grid's Show Titles setting; nil where there is none.
    var showTitles: Binding<Bool>?
    /// Starts Select mode; nil where books cannot be selected.
    var onSelect: (() -> Void)?
    var coverInfo = CoverInfoSettings()

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // Tap to show or hide the info on the covers; hold to choose what it shows.
            Menu {
                // Menus draw toggles as checkmark items; keep the app's switch style out of them.
                Toggle("Show Info on Covers", systemImage: "info.circle", isOn: coverInfo.$isOn)
                    .toggleStyle(.automatic)
                Section("Show") {
                    CoverInfoFieldControls()
                        .toggleStyle(.automatic)
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
                    // Its own submenu, so the many orders don't crowd this menu.
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(sortOptions) { Text($0.label(byName: sortsByName)).tag($0) }
                        }
                        .pickerStyle(.inline)
                        if let sortAscending {
                            Picker("Order", selection: sortAscending) {
                                Text("Ascending").tag(true)
                                Text("Descending").tag(false)
                            }
                            .pickerStyle(.inline)
                            .accessibilityIdentifier("library-sort-direction")
                        }
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                        Text(sort.label(byName: sortsByName))
                    }
                    .accessibilityIdentifier("library-sort")
                }
                Section("Cover Size (or pinch the grid)") {
                    // The menu stays open, so a few taps step through the sizes (#98).
                    Button("Larger", systemImage: "plus.magnifyingglass") { coverSize = min(LibraryGridView.sizeRange.upperBound, coverSize + 30) }
                        .menuActionDismissBehavior(.disabled)
                        .disabled(coverSize >= LibraryGridView.sizeRange.upperBound)
                        .accessibilityIdentifier("library-cover-larger")
                    Button("Smaller", systemImage: "minus.magnifyingglass") { coverSize = max(LibraryGridView.sizeRange.lowerBound, coverSize - 30) }
                        .menuActionDismissBehavior(.disabled)
                        .disabled(coverSize <= LibraryGridView.sizeRange.lowerBound)
                        .accessibilityIdentifier("library-cover-smaller")
                }
                if let showTitles {
                    Section {
                        Toggle("Show Titles", systemImage: "textformat", isOn: showTitles)
                            .toggleStyle(.automatic)
                            .accessibilityIdentifier("library-show-titles")
                    }
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

/// Fades the trailing edge of Continue Reading so covers dissolve before they reach the letter
/// index and its letters stay readable (#65). A mask rather than a painted overlay, so covers and
/// their shadows fade to whatever is behind them, in light and dark mode alike. The mask stays on
/// when the index is hidden (just fully opaque), so turning it on or off keeps the row's scroll spot.
struct EdgeFade: ViewModifier {
    let isOn: Bool

    /// Fully clear under the index: its 20 pt strip plus 2 pt to the screen edge.
    static let clearWidth: CGFloat = 22
    /// The soft part, just inside the index.
    static let fadeWidth: CGFloat = 40
    /// Trailing content margin, so the last cover scrolls fully clear of the fade.
    static let trailingRoom: CGFloat = clearWidth + fadeWidth + 8

    func body(content: Content) -> some View {
        content.mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: isOn ? Self.fadeWidth : 0)
                Color.clear
                    .frame(width: isOn ? Self.clearWidth : 0)
            }
            // Reach past the row above and below, so the icon row and the cover shadows that
            // scrollClipDisabled() lets through are not cut off; and past the leading edge.
            .padding(.vertical, -24)
            .padding(.leading, -24)
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

/// Series as stacks of covers; each opens a grid of that series' books in volume order. The
/// same grid shows authors and publishers (#78), each a stack of their first covers.
struct SeriesGridView: View {
    enum Kind {
        case series, authors, publishers

        var item: SidebarItem {
            switch self {
            case .series: return .series
            case .authors: return .authors
            case .publishers: return .publishers
            }
        }

        func item(for name: String) -> SidebarItem {
            switch self {
            case .series: return .seriesNamed(name)
            case .authors: return .author(name)
            case .publishers: return .publisher(name)
            }
        }

        var prefix: String {
            switch self {
            case .series: return "series"
            case .authors: return "author"
            case .publishers: return "publisher"
            }
        }
    }

    @Environment(AppModel.self) private var model
    var kind: Kind = .series
    @State private var search = ""
    @State private var showSettings = false
    /// Its own sort, apart from the books' and folders' (#100), one for each kind.
    @AppStorage private var sort: LibraryGridView.SortOrder

    init(kind: Kind = .series) {
        self.kind = kind
        _sort = AppStorage(wrappedValue: .title, kind == .series ? "seriesSortOrder" : "\(kind.prefix)SortOrder")
    }

    private func allGroups(_ model: AppModel) -> [SeriesGroup] {
        switch kind {
        case .series: return model.catalog.series
        case .authors: return model.catalog.authors
        case .publishers: return model.catalog.publishers
        }
    }
    @AppStorage("coverSize") private var coverSize: Double = 150
    @AppStorage(TitleGrid.series.key) private var showTitles = true
    @Environment(\.coverStyle) private var style
    @Environment(\.colorScheme) private var colorScheme
    /// Keeps the grid's place for the session, for coming back to it (#105).
    @State private var keeper = ScrollKeeper()

    var body: some View {
        // Read here: the menus use it later, after the grid has been drawn.
        let model = model
        let query = SearchQuery(search)
        let _ = query.isEmpty ? 0 : model.searchKeysRevision
        let groups = sorted(allGroups(model).filter { query.isEmpty || query.matches(model.searchKey($0.name)) })
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ScrollTopMarker()
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 20, alignment: .top)], spacing: 24) {
                        ForEach(groups) { group in
                            let item = kind.item(for: group.name)
                            let liftID = "\(kind.prefix):\(group.name)"
                            NavigationLink(value: item) {
                                SeriesCell(group: group, liftID: liftID)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("\(kind.prefix)-\(group.name.isEmpty ? "Unknown" : group.name)")
                            // Pin to Sidebar, as for folders (#72), with the same lift as books (#71).
                            .liftMenu(id: liftID, menu: { LiftMenuItems.group(item, model: model) },
                                      preview: seriesPreview(group),
                                      cover: { group.books.first.flatMap { model.coverNow(for: $0.id) } })
                        }
                    }
                    .scrollTargetLayout()
                    .padding()
                    .liftMenuHost()
                }
            }
            .remembersScroll(keeper, item: kind.item, ids: groups.map(\.id), isFiltered: !search.isEmpty,
                             proxy: proxy, clearSearch: { search = "" })
        }
        .environment(\.showTitles, showTitles)
        .overlay {
            if groups.isEmpty && !model.isScanning {
                if search.isEmpty {
                    switch kind {
                    case .series: ContentUnavailableView("No Series", systemImage: "square.stack")
                    case .authors: ContentUnavailableView("No Authors", systemImage: "person.2", description: Text("Authors come from each book's ComicInfo.xml, its file name, or your edits in Book Info."))
                    case .publishers: ContentUnavailableView("No Publishers", systemImage: "building.columns", description: Text("Publishers come from each book's ComicInfo.xml, its file name, or your edits in Book Info."))
                    }
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle(kind.item.title)
        .searchableWithHistory(text: $search, prompt: kind == .series ? "Search series" : kind == .authors ? "Search authors" : "Search publishers",
                               list: kind == .series ? "series" : kind == .authors ? "authors" : "publishers")
        .toolbar { LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, sortOptions: LibraryGridView.SortOrder.forGroups, sortsByName: true, showTitles: $showTitles) }
        .sheet(isPresented: $showSettings) { SettingsView().toggleStyle(MonoToggleStyle()) }
    }

    /// The catalog keeps series by name; the other orders go by each series' newest book.
    private func sorted(_ groups: [SeriesGroup]) -> [SeriesGroup] {
        switch sort {
        case .recentlyAdded:
            let latest = Dictionary(groups.map { ($0.id, $0.books.map(\.addedAt).max() ?? .distantPast) }, uniquingKeysWith: max)
            return groups.sorted { (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast) }
        case .recentlyRead:
            let latest = Dictionary(groups.map { ($0.id, $0.books.compactMap(\.lastReadAt).max() ?? .distantPast) }, uniquingKeysWith: max)
            return groups.sorted { (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast) }
        default:
            return groups
        }
    }

    /// Draws a series' stack for the lifted preview, with the grid's settings.
    private func seriesPreview(_ group: SeriesGroup) -> @MainActor () -> AnyView {
        let model = model
        var style = style
        style.shadowStrength = 0
        let colorScheme = colorScheme
        return {
            AnyView(
                SeriesStack(group: group, liftID: nil, preloaded: group.books.first.flatMap { model.coverNow(for: $0.id) })
                    .environment(model)
                    .environment(\.coverStyle, style)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.liftRendering, true)
            )
        }
    }
}

struct SeriesCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showTitles) private var showTitles
    let group: SeriesGroup
    var liftID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The stack lifts on a long press; the name stays (#71).
            SeriesStack(group: group, liftID: liftID)
                .modifier(LiftPart(liftID: liftID))
            if showTitles {
                Text(group.name.isEmpty ? "Unknown" : group.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                HStack(spacing: 4) {
                    Text(group.books.count == 1 ? "1 book" : "\(group.books.count) books")
                    // The average of the rated volumes (#84).
                    if let average = model.averageRating(of: group) {
                        Text("·")
                        Image(systemName: "star.fill").imageScale(.small)
                        Text(average.formatted(.number.precision(.fractionLength(0...1))))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A series' first cover with the volumes behind it peeking out above: the part of its tile
/// that lifts on a long press, drawn both in the grid and into the lifted preview.
struct SeriesStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverStyle) private var style
    let group: SeriesGroup
    var liftID: String?
    var preloaded: UIImage?

    var body: some View {
        let cover = group.books.first
        let cards = min(group.books.count - 1, 2)
        CoverImage(url: cover.flatMap { model.thumbnails[$0.id] }, title: group.name,
                   revision: cover.flatMap { model.coverRevision[$0.id] } ?? 0, preloaded: preloaded)
            .modifier(CoverPart(liftID: liftID, cornerRadius: style.cornerRadius, stackCards: cards))
            // The volumes behind the first one, peeking out above it.
            .background { StackCards(count: cards) }
            // Every tile keeps room for the stack, one book or many, so all the covers in a
            // row share a bottom edge and their names line up.
            .padding(.top, StackCards.peek)
            .onAppear { if let cover { model.requestCover(for: cover, urgent: true) } }
    }
}

struct BookCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverInfo) private var info
    @Environment(\.showTitles) private var showTitles
    @Environment(\.coverStyle) private var style
    @Environment(\.libraryIconSize) private var iconSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.liftMenu) private var liftMenu
    @Environment(\.gridOrder) private var gridOrder
    let book: Book
    /// Set in Select mode: whether the book is picked. A tap then picks or unpicks it.
    var isSelected: Bool?
    /// Tells this cell apart from the same book's cell elsewhere on the page (Continue Reading).
    var place = "grid"
    var onSelect: (() -> Void)?
    @State private var confirmDelete = false
    /// Regenerate Cover was picked for an edited cover, and waits for a yes (#89).
    @State private var confirmRegenerate = false

    var body: some View {
        let liftID = "\(place):\(book.id)"
        Button {
            if isSelected != nil {
                onSelect?()
            } else if liftMenu?.ignoresTap(on: liftID) == true {
                // The end of a long press that opened the menu, not a tap.
            } else {
                // Where it was opened from, so its last page can offer the next book (#83).
                model.readingContext = gridOrder.map { AppModel.ReadingContext(listName: $0.listName, ids: $0.books.map(\.id)) }
                Task { await model.activate(book) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // The icon row and cover lift together on a long press; the title stays (#71).
                BookCoverStack(book: book, isSelected: isSelected, liftID: liftID)
                    .liftMenuPart(.lift, id: liftID)
                if showTitles && !info.isOn {
                    // Every cell keeps room for two title lines, so all rows are the same height and the
                    // scroll bar does not jump as rows of different heights come into view.
                    Text(book.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2, reservesSpace: true)
                        .foregroundStyle(.primary)
                        .padding(.top, 1)
                }
            }
            // The whole cell is the tap target, and nothing outside it.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("book-\(book.title)")
        .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        .onAppear { model.requestCover(for: book, urgent: true) }
        .liftMenu(id: liftID, menu: menuMaker(), preview: previewMaker(), cover: { [model, id = book.id] in model.coverNow(for: id) })
        .confirmationDialog("Delete this book from the library?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from Library", role: .destructive) { model.deleteFromLibrary([book.id]) }
        } message: {
            Text(MissingBooks.deleteMessage)
        }
        // The same question as Book Info's (#89).
        .confirmationDialog("Regenerate this cover?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Regenerate Cover", role: .destructive) { Task { await model.regenerateCover(book) } }
        } message: {
            Text(CoverQuestions.regenerateEdited)
        }
    }

    /// The long-press menu, made when the press happens from the book as it is then. None in
    /// Select mode. Everything it uses is read here, while the cell is being drawn.
    private func menuMaker() -> @MainActor () -> UIMenu? {
        let model = model
        let id = book.id
        let fallback = book
        let selecting = isSelected != nil
        let confirmDelete = $confirmDelete
        let confirmRegenerate = $confirmRegenerate
        return {
            guard !selecting else { return nil }
            return BookMenu.make(model.book(id: id) ?? fallback, model: model,
                                 confirmDelete: { confirmDelete.wrappedValue = true },
                                 confirmRegenerate: { confirmRegenerate.wrappedValue = true })
        }
    }

    /// Draws the icon row and cover for the lifted preview, with this cell's settings.
    private func previewMaker() -> @MainActor () -> AnyView {
        let model = model
        let book = book
        // The lifted copy gets the system's own shadow, shaped like the cover, instead.
        var style = style
        style.shadowStrength = 0
        let info = info
        let iconSize = iconSize
        let colorScheme = colorScheme
        return {
            AnyView(
                BookCoverStack(book: model.book(id: book.id) ?? book, isSelected: nil, liftID: nil,
                               preloaded: model.coverNow(for: book.id))
                    .environment(model)
                    .environment(\.coverStyle, style)
                    .environment(\.coverInfo, info)
                    .environment(\.libraryIconSize, iconSize)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.liftRendering, true)
            )
        }
    }
}

/// A book's long-press menu, as a UIKit menu so the lifted cover can look right (#71). Its
/// groups come in the same order as Select mode's Actions menu (#91): the book itself, Favorite,
/// reading, the file, and the cover.
@MainActor
enum BookMenu {
    static func make(_ book: Book, model: AppModel, confirmDelete: @escaping () -> Void,
                     confirmRegenerate: @escaping () -> Void) -> UIMenu {
        typealias Item = LiftMenuItems
        let info = Item.action("Book Info", "info.circle") { model.bookInfo = .init(id: book.id) }
        if book.isMissing {
            // The file is gone: all that is left to do is to delete what the app kept of it.
            return UIMenu(title: "", children: [
                info,
                Item.action("Delete from Library", "trash", destructive: true, confirmDelete),
            ])
        }
        let top: [UIMenuElement] = [
            info,
            Item.action("Edit Info…", "pencil") { model.dataEditor = .init(ids: [book.id]) },
            Item.action("Tags…", "tag") { model.tagEditor = .init(ids: [book.id]) },
            Item.action("Add to Reading List…", "text.badge.plus") { model.listPicker = .init(ids: [book.id]) },
        ] + pinMenu(book, model: model)
        var marks: [UIMenuElement] = [
            Item.action(book.favorite ? "Remove from Favorites" : "Favorite", book.favorite ? "heart.slash" : "heart") {
                model.setFavorite(book, !book.favorite)
            },
            ratingMenu(book, model: model),
        ]
        // Bookmarks are pages now (#96); a book bookmarked the old way can still drop it.
        if book.bookmarked {
            marks.append(Item.action("Remove Bookmark", "bookmark.slash") { model.setBookmarked(book, false) })
        }
        var reading: [UIMenuElement] = []
        if book.status != .read {
            reading.append(Item.action("Mark as Read", "checkmark.circle") { model.setFinished(book, true) })
        }
        // Also for a book in progress: it goes back to as if never opened.
        if book.status != .unread {
            reading.append(Item.action("Mark as Unread", "circle") { model.setFinished(book, false) })
        }
        reading.append(directionMenu(book, model: model))
        // Hides the series from Up Next until a volume of it is read again (#85).
        if model.upNext.contains(book.id) {
            reading.append(Item.action("Not Interested", "hand.thumbsdown") { model.hideFromUpNext(series: book.series) })
        }
        let file: UIMenuElement
        if book.isDownloaded {
            file = Item.action("Remove from iPad", "icloud.and.arrow.up") { model.removeDownload(book) }
        } else {
            file = Item.action("Download", "icloud.and.arrow.down") { Task { await model.download(book) } }
        }
        return UIMenu(title: "", children: [
            Item.section(top), Item.section(marks), Item.section(reading), Item.section([file]),
            coverMenu(book, model: model, confirmRegenerate: confirmRegenerate),
        ])
    }

    /// Rating ▸ one to five stars, with the current one checked, and No Rating (#84).
    private static func ratingMenu(_ book: Book, model: AppModel) -> UIMenu {
        var items: [UIMenuElement] = (1...5).reversed().map { stars in
            let action = LiftMenuItems.action(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars), "star") {
                model.setRating([book.id], stars)
            }
            action.state = book.rating == stars ? .on : .off
            action.accessibilityLabel = stars == 1 ? "1 star" : "\(stars) stars"
            return action
        }
        if book.rating != nil {
            items.append(LiftMenuItems.action("No Rating", "star.slash") { model.setRating([book.id], nil) })
        }
        return UIMenu(title: "Rating", image: UIImage(systemName: book.rating == nil ? "star" : "star.fill"), children: items)
    }

    /// Reading Direction, with the book's current one checked (#91).
    private static func directionMenu(_ book: Book, model: AppModel) -> UIMenu {
        let rightToLeft = model.direction(of: book) == .rightToLeft
        let ltr = LiftMenuItems.action("Left to Right", "arrow.right") { model.saveDirection(bookId: book.id, rightToLeft: false) }
        let rtl = LiftMenuItems.action("Right to Left (Manga)", "arrow.left") { model.saveDirection(bookId: book.id, rightToLeft: true) }
        ltr.state = rightToLeft ? .off : .on
        rtl.state = rightToLeft ? .on : .off
        return UIMenu(title: "Reading Direction", image: UIImage(systemName: "arrow.left.arrow.right"), children: [ltr, rtl])
    }

    /// Cover ▸ Edit Cover…, Use Default Cover and Regenerate Cover (#95). Whether the cover is
    /// edited is in the book's record, read as the submenu opens; an edited cover offers Use
    /// Default Cover, and Regenerate Cover asks first, as in Book Info (#89).
    private static func coverMenu(_ book: Book, model: AppModel, confirmRegenerate: @escaping () -> Void) -> UIMenu {
        let edit = LiftMenuItems.action("Edit Cover…", "crop") { Task { await model.editCover(book) } }
        let rest = UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                let edited = await model.record(for: book.id)?.cover.map { !$0.isDefault } == true
                var items: [UIMenuElement] = []
                if edited {
                    items.append(LiftMenuItems.action("Use Default Cover", "arrow.uturn.backward") {
                        Task { await model.resetCover(book) }
                    })
                }
                items.append(LiftMenuItems.action("Regenerate Cover", "arrow.triangle.2.circlepath") {
                    if edited { confirmRegenerate() } else { Task { await model.regenerateCover(book) } }
                })
                completion(items)
            }
        }
        return UIMenu(title: "Cover", image: UIImage(systemName: "photo"), children: [edit, rest])
    }

    /// Pin… with Pin Series and Pin Folder for the book's series and folder (#72). Each one
    /// says Unpin when it is already pinned. None for a book with neither.
    private static func pinMenu(_ book: Book, model: AppModel) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        let series = book.series.trimmingCharacters(in: .whitespaces)
        if !series.isEmpty {
            // The series' name as the Series view has it, so a pin made here or there is the same.
            let name = model.catalog.series.first { $0.name.caseInsensitiveCompare(series) == .orderedSame }?.name ?? series
            items.append(pinAction(.seriesNamed(name), noun: "Series", model: model))
        }
        // Books at the top of the library are in no folder that can be pinned.
        if !book.folder.isEmpty, model.catalog.folders[book.folder] != nil {
            items.append(pinAction(.folder(book.folder), noun: "Folder", model: model))
        }
        guard !items.isEmpty else { return [] }
        return [UIMenu(title: "Pin…", image: UIImage(systemName: "pin"), children: items)]
    }

    private static func pinAction(_ item: SidebarItem, noun: String, model: AppModel) -> UIAction {
        let pinned = model.isPinned(item)
        return LiftMenuItems.action(pinned ? "Unpin \(noun)" : "Pin \(noun)", pinned ? "pin.slash" : "pin") {
            model.setPinned(item, !pinned)
        }
    }
}

/// A book's icon row and cover: the part of its cell that lifts on a long press, drawn both in
/// the grid and into the lifted preview.
struct BookCoverStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.coverInfo) private var info
    @Environment(\.coverStyle) private var style
    @Environment(\.libraryIconSize) private var iconSize
    @Environment(\.liftRendering) private var rendering
    let book: Book
    var isSelected: Bool?
    /// The cell's long-press menu id, so the cover can report where it is. Nil in the preview.
    var liftID: String?
    var preloaded: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            iconRow
            CoverImage(url: model.thumbnails[book.id], title: book.title, revision: model.coverRevision[book.id] ?? 0,
                       preloaded: preloaded)
                .overlay {
                    if info.isOn {
                        CoverInfoOverlay(book: book)
                    }
                }
                .overlay(alignment: .topTrailing) { if !info.isOn { badge } }
                .overlay(alignment: .topLeading) { selectionMark }
                .modifier(CoverPart(liftID: liftID, cornerRadius: style.cornerRadius))
        }
    }

    /// Favorite, bookmark, tags and how far in, in a row above the cover starting at the left
    /// (#57). It keeps its height with nothing in it, so every cell is the same height.
    private var iconRow: some View {
        // Each icon keeps its own slot, shown or not, so a heart, bookmark or tag sits in the
        // same place on every book; the percentage keeps to the right edge.
        HStack(spacing: iconSize * 0.4) {
            slot("heart.fill", .pink, book.favorite)
            slot("bookmark.fill", .orange, book.hasBookmarks)
            slot("tag.fill", .teal, !book.tags.isEmpty)
            Spacer(minLength: 2)
            if book.status == .read {
                // Finished: a solid tab standing on the cover's top edge, where the percentage
                // would be. An overlay, so the row keeps the same height as every other book's.
                Text(verbatim: "72%")
                    .monospacedDigit()
                    .fixedSize()
                    .hidden()
                    .overlay(alignment: .bottomTrailing) { readTab }
                    .accessibilityElement()
                    .accessibilityLabel("Read")
            } else if book.status == .reading, let fraction = book.progressFraction {
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .fixedSize() // never cut short to "…"
                    .foregroundStyle(.secondary)
            }
        }
        // Sized with the covers (see `LibraryIconSize`), so the row fits at every zoom level.
        .font(.system(size: iconSize, weight: .semibold))
        .imageScale(.medium)
        .lineLimit(1)
        // Kept in from the ends so nothing sits over the cover's rounded corners.
        .padding(.horizontal, max(style.cornerRadius, 3) + iconSize * 0.15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Read mark: a check on a tab with rounded top corners (black and white in light mode,
    /// soft greys in dark mode, see `Color.readTabFill`), reaching down
    /// to touch the cover; the row's padding keeps it clear of the cover's rounded corner.
    private var readTab: some View {
        UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6, style: .continuous)
            .fill(Color.readTabFill)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: iconSize, weight: .heavy))
                    .foregroundStyle(Color.readTabCheck)
                    .padding(.top, 1)
            }
            .frame(width: iconSize * 2.6, height: iconSize * 1.75)
            .offset(y: 5) // 5 = the gap between row and cover
            .allowsHitTesting(false)
    }

    private func slot(_ symbol: String, _ color: Color, _ shown: Bool) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
    }

    @ViewBuilder private var selectionMark: some View {
        if let isSelected {
            // Selected: a primary circle with an inverse checkmark and a thin inverse outline, so
            // it shows on any cover in light and dark mode (#55).
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.onAccent : Color.white,
                                 isSelected ? Color.primary : Color.black.opacity(0.25))
                .background {
                    if isSelected { Circle().stroke(Color.onAccent, lineWidth: 1.5).padding(1) }
                }
                .shadow(color: .black.opacity(0.35), radius: 2)
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var badge: some View {
        if model.downloading.contains(book.id) {
            ProgressView().padding(6).badgeBackground(plain: rendering).padding(6)
        } else if !book.isDownloaded {
            Image(systemName: model.queuedDownloads.contains(book.id) ? "icloud.and.arrow.down" : "icloud")
                .font(.caption.weight(.semibold))
                .padding(6)
                .badgeBackground(plain: rendering)
                .padding(6)
        }
        // A read book's check is in the row above the cover.
    }
}

/// Marks the part of a tile that lifts. Nothing in a lifted preview.
struct LiftPart: ViewModifier {
    let liftID: String?

    func body(content: Content) -> some View {
        if let liftID {
            content.liftMenuPart(.lift, id: liftID)
        } else {
            content
        }
    }
}

/// Reports where a tile's cover is, for the lifted shadow. Nothing in a lifted preview.
struct CoverPart: ViewModifier {
    let liftID: String?
    let cornerRadius: CGFloat
    var stackCards = 0

    func body(content: Content) -> some View {
        if let liftID {
            content.liftMenuPart(.cover, id: liftID, cornerRadius: cornerRadius, stackCards: stackCards)
        } else {
            content
        }
    }
}

extension View {
    /// The round glass behind a badge on a cover. Glass needs the screen behind it, so the
    /// lifted preview, drawn into an image, gets a plain fill instead.
    @ViewBuilder func badgeBackground(plain: Bool) -> some View {
        if plain {
            background(Circle().fill(Color(.secondarySystemBackground).opacity(0.9)))
        } else {
            glassEffect(in: .circle)
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

enum CoverQuestions {
    static let regenerateEdited = "Your edited cover is removed on all your devices, and a new cover is made from the first page."
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
            let allRead = books.allSatisfy { $0.status == .read }
            // The same order as a book's long-press menu (#91).
            Section {
                // Keeps the selection when the sheet closes, so another action can follow (#64).
                Button("Tags…", systemImage: "tag") { model.tagEditor = .init(ids: ids) }
                    .accessibilityIdentifier("selection-tags")
                // Fields that differ show as Mixed; only what you change is written (#76).
                Button("Edit Info…", systemImage: "pencil") { model.dataEditor = .init(ids: ids) }
                    .accessibilityIdentifier("selection-edit-info")
                // In the order they are on screen (#83).
                Button("Add to Reading List…", systemImage: "text.badge.plus") {
                    model.listPicker = .init(ids: visible.filter(ids.contains))
                }
                .accessibilityIdentifier("selection-add-to-list")
                if case .readingList(let listId) = item {
                    Button("Remove from List", systemImage: "minus.circle") {
                        finish {
                            let kept = (model.lists.list(listId)?.bookIds ?? []).filter { !ids.contains($0) }
                            model.setListBooks(listId, kept)
                        }
                    }
                }
            }
            Section {
                Button(allFavorite ? "Remove from Favorites" : "Favorite", systemImage: allFavorite ? "heart.slash" : "heart") {
                    finish { model.setFavorite(ids, !allFavorite) }
                }
                // Bookmarks are pages now (#96); books bookmarked the old way can still drop it.
                if books.contains(where: \.bookmarked) {
                    Button("Remove Bookmark", systemImage: "bookmark.slash") { finish { model.setBookmarked(ids, false) } }
                }
                Menu("Rating", systemImage: "star") {
                    ForEach((1...5).reversed(), id: \.self) { stars in
                        Button(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)) {
                            finish { model.setRating(ids, stars) }
                        }
                        .accessibilityLabel(stars == 1 ? "1 star" : "\(stars) stars")
                    }
                    if books.contains(where: { $0.rating != nil }) {
                        Button("No Rating", systemImage: "star.slash") { finish { model.setRating(ids, nil) } }
                    }
                }
                .accessibilityIdentifier("selection-rating")
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
                Menu("Reading Direction", systemImage: "arrow.left.arrow.right") {
                    Button("Left to Right") { finish { model.setDirection(ids, .leftToRight) } }
                    Button("Right to Left (Manga)") { finish { model.setDirection(ids, .rightToLeft) } }
                }
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
    /// The image to show at once, for a copy drawn into an image (the long-press preview),
    /// which gets no chance to load it.
    var preloaded: UIImage?
    @Environment(\.coverStyle) private var style
    @State private var loaded: UIImage?

    private struct Key: Equatable { let url: URL?; let revision: Int }

    var body: some View {
        // A cover seen before is shown at once from memory, with no placeholder in between.
        let image = preloaded ?? loaded ?? url.flatMap { CoverMemoryCache.shared.image(for: $0, revision: revision) }
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

    /// The cover now: from memory, or read and decoded here if it has been let go. For the
    /// long-press preview, which is drawn at once and cannot wait for a load (#71).
    @MainActor func imageNow(for url: URL, revision: Int) -> UIImage? {
        if let image = image(for: url, revision: revision) { return image }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
        insert(image, for: url, revision: revision)
        return image
    }

    func insert(_ image: UIImage, for url: URL, revision: Int) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: key(url, revision), cost: cost)
    }
}
