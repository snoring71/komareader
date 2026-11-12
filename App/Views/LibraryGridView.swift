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

    /// Letter sections, when sorted by title. Each letter appears once, in the order first met.
    struct LetterSection: Identifiable {
        let key: String
        let books: [Book]
        var id: String { key }
    }

    private func letterSections(_ books: [Book]) -> [LetterSection]? {
        guard sort == .title, appliedSearch.isEmpty, books.count > 24 else { return nil }
        if case .seriesNamed = item { return nil }
        var order: [String] = []
        var grouped: [String: [Book]] = [:]
        for book in books {
            let key = model.catalog.indexKey[book.id] ?? IndexKey.of(book.title)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(book)
        }
        guard order.count > 1 else { return nil }
        return order.map { LetterSection(key: $0, books: grouped[$0] ?? []) }
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
        let sections = letterSections(books)
        let continueReading = item == .all && search.isEmpty ? continueReading : []
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

                if let sections {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.books) { BookCell(book: $0) }
                            } header: {
                                Text(section.key)
                                    .font(.title3.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 6)
                                    .id(LetterIndex.anchor(section.key))
                            }
                        }
                    }
                    .padding()
                    .padding(.trailing, 14) // room for the letter index
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(books) { BookCell(book: $0) }
                    }
                    .padding()
                }
            }
            .overlay(alignment: .trailing) {
                if let sections {
                    LetterIndex(keys: sections.map(\.key)) { key in
                        proxy.scrollTo(LetterIndex.anchor(key), anchor: .top)
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
                } else if item == .bookmarked {
                    ContentUnavailableView("No Bookmarked Books", systemImage: "bookmark", description: Text("Books you bookmark appear here."))
                } else {
                    ContentUnavailableView("No Books", systemImage: "books.vertical", description: Text("Comics you add to \(model.libraryName) appear here."))
                }
            }
        }
        .navigationTitle(item.title)
        .searchable(text: $search, prompt: "Search books")
        .task(id: search) {
            // Filtering thousands of books on every keystroke makes typing lag, so wait for a pause.
            if !search.isEmpty, (try? await Task.sleep(for: .milliseconds(200))) == nil { return }
            appliedSearch = search
        }
        .toolbar { LibraryToolbar(sort: $sort, coverSize: $coverSize, showSettings: $showSettings, showsSort: !isSeriesList) }
        .sheet(isPresented: $showSettings) { SettingsView() }
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

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
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

    static func anchor(_ key: String) -> String { "letter-\(key)" }

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
    let group: SeriesGroup

    var body: some View {
        let cover = group.books.first
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                // A hint of the volumes behind the first one.
                if group.books.count > 1 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.systemGray3))
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
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
    let book: Book

    var body: some View {
        Button {
            Task { await model.open(book) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverImage(url: model.thumbnails[book.id], title: book.title, revision: model.coverRevision[book.id] ?? 0)
                    .overlay(alignment: .topTrailing) { badge }
                    .overlay(alignment: .bottom) { progressBar }
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
        .buttonStyle(.plain)
        .accessibilityIdentifier("book-\(book.title)")
        .onAppear { model.requestCover(for: book, urgent: true) }
        .contextMenu {
            Button("Book Info", systemImage: "info.circle") { model.bookInfo = .init(id: book.id) }
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

    private var statusText: String {
        if model.downloading.contains(book.id) { return "Downloading…" }
        switch book.status {
        case .read: return "Read"
        case .reading: return book.progressFraction.map { "\(Int($0 * 100))%" } ?? "Reading"
        case .unread: return book.format.displayName
        }
    }

    @ViewBuilder private var badge: some View {
        if model.downloading.contains(book.id) {
            ProgressView().padding(6).glassEffect(in: .circle).padding(6)
        } else if !book.isDownloaded {
            Image(systemName: "icloud")
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

/// A cover thumbnail, decoded off the main thread, with a placeholder until it is ready.
struct CoverImage: View {
    let url: URL?
    let title: String
    /// Changes when the cover file is replaced at the same URL (after a cover edit).
    var revision: Int = 0
    @State private var image: UIImage?

    private struct Key: Equatable { let url: URL?; let revision: Int }

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Text(title)
                        .font(.caption.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            .task(id: Key(url: url, revision: revision)) {
                guard let url else { image = nil; return }
                image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return UIImage(data: data)?.preparingForDisplay()
                }.value
            }
    }
}
