import ArchiveKit
import ComicCore
import LibraryKit
import SwiftUI

/// The Book Info sheet: cover, reading status, Favorite and tags, reader settings,
/// details, the file and its download state.
struct BookInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bookId: String
    /// The open book's pages, when shown from the reader (saves opening the book again).
    var source: BookSource?

    @State private var editingCover = false
    @State private var coverEdit: BookRecord.CoverEdit?
    @State private var confirmRegenerate = false
    /// Whether the book has reader settings of its own, read from its record.
    @State private var hasOwnOptions = false
    @State private var confirmResetOptions = false

    private var book: Book? { model.books.first { $0.id == bookId } }

    var body: some View {
        NavigationStack {
            if let book {
                form(book)
                    .navigationTitle("Book Info")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("info-done")
                        }
                    }
                    .fullScreenCover(isPresented: $editingCover) {
                        CoverEditorView(book: book, source: source, initialEdit: coverEdit)
                    }
                    .task(id: model.coverRevision[book.id]) {
                        let record = await model.record(for: book.id)
                        coverEdit = record?.cover
                        hasOwnOptions = record.map { !$0.effectiveReaderOptions.isEmpty } ?? false
                    }
            } else {
                ContentUnavailableView("Book Not Found", systemImage: "book.closed")
            }
        }
    }

    private func form(_ book: Book) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    CoverImage(url: model.thumbnails[book.id], title: book.title, revision: model.coverRevision[book.id] ?? 0)
                        .frame(width: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(book.title).font(.title3.bold()).lineLimit(3)
                        if let number = book.number {
                            Text("\(book.series) · \(number)").foregroundStyle(.secondary)
                        } else if book.series != book.title {
                            Text(book.series).foregroundStyle(.secondary)
                        }
                        Text(statusText(book)).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Edit Cover…", systemImage: "crop") { editingCover = true }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("info-edit-cover")
                        if coverEdit.map({ !$0.isDefault }) == true {
                            Button("Use Default Cover", systemImage: "arrow.uturn.backward") {
                                Task { await model.resetCover(book) }
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                        }
                        Button("Regenerate Cover", systemImage: "arrow.triangle.2.circlepath") {
                            if coverEdit.map({ !$0.isDefault }) == true {
                                confirmRegenerate = true
                            } else {
                                Task { await model.regenerateCover(book) }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .accessibilityIdentifier("info-regenerate-cover")
                        .confirmationDialog("Regenerate this cover?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                            Button("Regenerate Cover", role: .destructive) { Task { await model.regenerateCover(book) } }
                        } message: {
                            Text(CoverQuestions.regenerateEdited)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                Picker("Reading Status", selection: Binding(
                    get: { book.status },
                    set: { status in
                        switch status {
                        case .unread: model.setFinished(book, false)
                        case .reading: model.markReading(book)
                        case .read: model.setFinished(book, true)
                        }
                    }
                )) {
                    Text("Unread").tag(Book.Status.unread)
                    Text(book.status == .reading ? "Reading (\(percent(book)))" : "Reading").tag(Book.Status.reading)
                    Text("Read").tag(Book.Status.read)
                }
                .accessibilityIdentifier("info-status")
                if !book.pageBookmarks.isEmpty {
                    LabeledContent {
                        Text(book.pageBookmarks.map { String($0 + 1) }.joined(separator: ", "))
                    } label: {
                        Label("Bookmarked Pages", systemImage: "bookmark.fill")
                    }
                }
                Toggle(isOn: Binding(get: { book.favorite }, set: { model.setFavorite(book, $0) })) {
                    Label("Favorite", systemImage: "heart")
                }
                .accessibilityIdentifier("info-favorite")
                // Bookmarks are pages now (#96); a book bookmarked the old way can still drop it.
                if book.bookmarked {
                    Button("Remove Bookmark", systemImage: "bookmark.slash") { model.setBookmarked(book, false) }
                        .tint(.primary)
                        .accessibilityIdentifier("info-remove-bookmark")
                }
                NavigationLink {
                    TagEditorView(bookIds: [book.id], inSheet: false)
                } label: {
                    LabeledContent {
                        Text(book.tags.isEmpty ? "None" : book.tags.joined(separator: ", ")).lineLimit(1)
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                }
                .accessibilityIdentifier("info-tags")
            }

            Section("Reader") {
                Picker("Reading Direction", selection: Binding(
                    get: { model.direction(of: book) == .rightToLeft },
                    set: { model.saveDirection(bookId: book.id, rightToLeft: $0) }
                )) {
                    Text("Left to Right").tag(false)
                    Text("Right to Left (Manga)").tag(true)
                }
                // From the library only: the reader has its own Use Defaults.
                if source == nil, hasOwnOptions || book.direction != nil {
                    Button("Reset to Defaults", systemImage: "arrow.uturn.backward") { confirmResetOptions = true }
                        .tint(.primary)
                        .accessibilityIdentifier("info-reset-reader-options")
                        .confirmationDialog("Reset this book's reader settings?", isPresented: $confirmResetOptions, titleVisibility: .visible) {
                            Button("Reset to Defaults", role: .destructive) {
                                model.resetReaderOptions(bookId: book.id)
                                hasOwnOptions = false
                            }
                        } message: {
                            Text(ReaderResetText.message)
                        }
                }
            }

            Section {
                bookData(book)
                NavigationLink {
                    BookDataEditorView(bookIds: [book.id], inSheet: false)
                } label: {
                    Label("Edit Info…", systemImage: "pencil")
                }
                .accessibilityIdentifier("info-edit-data")
            } header: {
                Text("Book")
            } footer: {
                if book.userData != nil {
                    Text("Some of this was edited by you. Edits sync to your other devices; the file is not changed.")
                }
            }

            Section("Details") {
                LabeledContent("Format", value: book.format.displayName)
                LabeledContent("Pages", value: book.pageCount.map(String.init) ?? "–")
                LabeledContent("Size", value: book.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–")
                LabeledContent("Added", value: book.addedAt.formatted(date: .abbreviated, time: .omitted))
                if let modified = book.modified {
                    LabeledContent("Modified", value: modified.formatted(date: .abbreviated, time: .omitted))
                }
                if let read = book.lastReadAt {
                    LabeledContent("Last Read", value: read.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                LabeledContent("Location") {
                    Text("\(model.libraryName)/\(book.relativePath)")
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                if model.downloading.contains(book.id) {
                    LabeledContent("On This iPad") { ProgressView() }
                } else if book.isDownloaded {
                    LabeledContent("On This iPad", value: "Yes")
                    Button("Remove from iPad", systemImage: "icloud.and.arrow.up") { model.removeDownload(book) }
                } else {
                    LabeledContent("On This iPad", value: "No, in iCloud only")
                    Button("Download", systemImage: "icloud.and.arrow.down") { Task { await model.download(book) } }
                }
            } header: {
                Text("File")
            } footer: {
                Text("Removing a book from this iPad keeps it in iCloud Drive.")
            }
        }
    }

    /// Everything known about the book (#75): the user's edits, the file's ComicInfo.xml, or
    /// what its file name says. Empty fields are left out.
    @ViewBuilder private func bookData(_ book: Book) -> some View {
        let info = book.info
        if let title = info.title, title != book.title { LabeledContent("Title", value: title) }
        LabeledContent("Series", value: book.series)
        if let number = book.number {
            LabeledContent("Number", value: info.count.map { "\(number) of \($0)" } ?? number)
        } else if let count = info.count {
            LabeledContent("Books in Series", value: String(count))
        }
        if let volume = info.volume, volume != book.number { LabeledContent("Volume", value: volume) }
        ForEach(BookData.Role.allCases) { role in
            if let names = info[keyPath: role.keyPath], !names.isEmpty {
                LabeledContent(names.count == 1 ? role.title : role.title + "s", value: names.joined(separator: ", "))
            }
        }
        if let publisher = info.publisher {
            LabeledContent("Publisher", value: info.imprint.map { "\(publisher) (\($0))" } ?? publisher)
        }
        if let released = Self.releaseText(info) { LabeledContent("Released", value: released) }
        if let genres = info.genres, !genres.isEmpty { LabeledContent("Genre", value: genres.joined(separator: ", ")) }
        if let tags = info.tags, !tags.isEmpty { LabeledContent("File Tags", value: tags.joined(separator: ", ")) }
        if let language = info.language {
            LabeledContent("Language", value: Locale.current.localizedString(forLanguageCode: language) ?? language)
        }
        if let rating = info.ageRating { LabeledContent("Age Rating", value: rating) }
        if let isbn = info.isbn {
            LabeledContent("ISBN") { Text(isbn).textSelection(.enabled) }
        }
        if let web = info.web, let url = URL(string: web), url.scheme?.hasPrefix("http") == true {
            LabeledContent("Web") {
                Link(url.host() ?? web, destination: url).foregroundStyle(.primary).underline()
            }
        }
        if info.rightToLeft == true { LabeledContent("Reads", value: "Right to Left (Manga)") }
        if let summary = info.summary {
            VStack(alignment: .leading, spacing: 4) {
                Text("Summary").foregroundStyle(.secondary).font(.subheadline)
                Text(summary).textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
    }

    /// "10 April 2005", "April 2005" or "2005".
    static func releaseText(_ info: BookData) -> String? {
        guard let year = info.year else { return nil }
        var parts = DateComponents()
        parts.year = year
        parts.month = info.month ?? 1
        parts.day = info.day ?? 1
        guard let date = Calendar(identifier: .gregorian).date(from: parts) else { return String(year) }
        if info.month == nil { return String(year) }
        if info.day == nil { return date.formatted(.dateTime.month(.wide).year()) }
        return date.formatted(date: .long, time: .omitted)
    }

    private func percent(_ book: Book) -> String {
        "\(Int((book.progressFraction ?? 0) * 100))%"
    }

    private func statusText(_ book: Book) -> String {
        switch book.status {
        case .unread: return "Unread"
        case .reading: return "Reading (\(percent(book)))"
        case .read: return "Read"
        }
    }
}
