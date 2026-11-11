import LibraryKit
import SwiftUI

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    @State private var search = ""
    @AppStorage("sortOrder") private var sort: SortOrder = .title
    @AppStorage("coverSize") private var coverSize: Double = 150

    enum SortOrder: String, CaseIterable, Identifiable {
        case title = "Title", recentlyAdded = "Recently Added", recentlyRead = "Recently Read"
        var id: String { rawValue }
    }

    private var visibleBooks: [Book] {
        var books = model.books.filter(item.includes)
        if !search.isEmpty {
            books = books.filter { $0.title.localizedStandardContains(search) || $0.folder.localizedStandardContains(search) }
        }
        switch sort {
        case .title: break // already natural path order
        case .recentlyAdded: books.sort { $0.addedAt > $1.addedAt }
        case .recentlyRead: books.sort { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
        }
        return books
    }

    private var continueReading: [Book] {
        model.books.filter { !$0.isMissing && $0.status == .reading }
            .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    }

    var body: some View {
        let books = visibleBooks
        ScrollView {
            if item == .all, search.isEmpty, !continueReading.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Continue Reading").font(.title3.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(continueReading.prefix(12)) { book in
                                BookCell(book: book).frame(width: coverSize)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 16, alignment: .top)], spacing: 22) {
                ForEach(books) { book in
                    BookCell(book: book)
                }
            }
            .padding()
        }
        .overlay {
            if books.isEmpty && !model.isScanning {
                if search.isEmpty {
                    ContentUnavailableView("No Books", systemImage: "books.vertical", description: Text("Comics you add to \(model.libraryName) appear here."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .navigationTitle(item.title)
        .searchable(text: $search, prompt: "Search books")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Section("Cover Size") {
                        Button("Larger", systemImage: "plus.magnifyingglass") { coverSize = min(260, coverSize + 30) }
                        Button("Smaller", systemImage: "minus.magnifyingglass") { coverSize = max(100, coverSize - 30) }
                    }
                    Section {
                        Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await model.rescan() } }
                        Button("Change Library Folder…", systemImage: "folder") { model.changeFolder() }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis")
                }
            }
            if model.isScanning {
                ToolbarItem(placement: .status) { ProgressView() }
            }
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
                CoverImage(url: model.thumbnails[book.id], title: book.title)
                    .overlay(alignment: .topTrailing) { badge }
                    .overlay(alignment: .bottom) { progressBar }
                Text(book.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("book-\(book.title)")
        .onAppear { model.requestCover(for: book, urgent: true) }
        .contextMenu {
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
    @State private var image: UIImage?

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
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return UIImage(data: data)?.preparingForDisplay()
                }.value
            }
    }
}
