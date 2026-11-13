import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.coverShape) private var coverShape: CoverShape = .comic
    @AppStorage(SettingsKeys.coverShadow) private var coverShadow: Double = CoverStyle.defaultShadowStrength

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
            case .needsFolder:
                WelcomeView()
            case .ready:
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    NavigationStack {
                        Group {
                            if model.selection == .series {
                                SeriesGridView()
                            } else {
                                LibraryGridView(item: model.selection ?? .all)
                            }
                        }
                        .navigationDestination(for: SidebarItem.self) { LibraryGridView(item: $0) }
                    }
                    // Start from the top of the stack when another sidebar item is picked.
                    .id(model.selection)
                    .overlay(alignment: .bottomTrailing) { ResumeButton() }
                }
            }
        }
        .fullScreenCover(item: $model.openBook) { open in
            ReaderScreen(book: open.book, source: open.source, handOff: open.handOff)
        }
        .sheet(item: $model.bookInfo) { ref in
            BookInfoView(bookId: ref.id)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .environment(\.coverStyle, CoverStyle(shape: coverShape, shadowStrength: coverShadow))
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Comics Folder", systemImage: "books.vertical")
        } description: {
            Text("Pick the iCloud Drive folder that holds your comics, such as iCloud Drive › Booklover. Books stay where they are; nothing in the folder is changed.")
        } actions: {
            Button("Choose Folder…") { showPicker = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Button("Use the Comic Reader Folder") { Task { await model.useAppFolder() } }
                .buttonStyle(.glass)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.choose(folder: url) }
            }
        }
    }
}

/// One glass button that opens the last book; a long press lists recent books.
struct ResumeButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let last = model.lastBook {
            Menu {
                Section("Recently Read") {
                    ForEach(model.recentBooks(limit: 8)) { book in
                        Button {
                            Task { await model.open(book) }
                        } label: {
                            Label(book.title, systemImage: book.status == .read ? "checkmark.circle" : "book")
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "book.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Resume").font(.headline)
                        Text(last.title).font(.caption).lineLimit(1).opacity(0.85)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            } primaryAction: {
                Task { await model.open(last) }
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .padding(24)
            .accessibilityIdentifier("resume-button")
        }
    }
}
