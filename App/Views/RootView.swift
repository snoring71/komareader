import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.coverShape) private var coverShape: CoverShape = .comic
    @AppStorage(SettingsKeys.coverShadow) private var coverShadow: Double = CoverStyle.defaultShadowStrength
    @AppStorage(SettingsKeys.coverShadowDirection) private var shadowDirection: CoverShadowDirection = .around
    @AppStorage(SettingsKeys.roundedCorners) private var roundedCorners = true
    var coverInfo = CoverInfoSettings()
    /// Whether the sidebar is out over the library. The toolbar's sidebar button and the
    /// swipes both change it.
    @State private var sidebarShown = false
    /// The reader restore (#66) is tried once, when the library is first ready.
    @State private var restoreTried = false

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
            case .needsFolder:
                WelcomeView()
            case .ready:
                // The sidebar floats over the library instead of sitting beside it (#56).
                SidebarOverlay(isShown: $sidebarShown, edgeSwipeEnabled: model.libraryPath.isEmpty) {
                    NavigationStack(path: $model.libraryPath) {
                        Group {
                            switch model.selection ?? .all {
                            case .series: SeriesGridView()
                            case .folders: FolderBrowserView()
                            case let item: LibraryGridView(item: item)
                            }
                        }
                        .toolbar { SidebarButton() }
                        .navigationDestination(for: SidebarItem.self) {
                            LibraryGridView(item: $0).toolbar { SidebarButton() }
                        }
                    }
                    // Start from the top of the stack when another sidebar item is picked.
                    .id(model.selection)
                    .overlay(alignment: .bottomTrailing) { ResumeButton() }
                } sidebar: {
                    SidebarView()
                }
                .environment(\.sidebarToggle, SidebarToggleAction(
                    toggle: { withAnimation(.snappy(duration: 0.28)) { sidebarShown.toggle() } },
                    close: { withAnimation(.snappy(duration: 0.28)) { sidebarShown = false } }
                ))
                // Picking something in the sidebar puts it away: a short pause so the new
                // highlight shows first, then a slower slide out.
                .onChange(of: model.selection) {
                    guard sidebarShown else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        withAnimation(.easeInOut(duration: 0.45)) { sidebarShown = false }
                    }
                }
            }
        }
        .onChange(of: model.openBook?.id) { _, id in
            ReaderRestore.note(bookId: id)
        }
        // Once the library is showing (and its position restored underneath), back into the
        // book that was open when the app last ended.
        .task(id: model.phase) {
            guard model.phase == .ready, !restoreTried else { return }
            restoreTried = true
            guard let id = ReaderRestore.savedBook else { return }
            await model.restoreReader(bookId: id)
            if model.openBook == nil { ReaderRestore.clear() }
        }
        .fullScreenCover(item: $model.openBook) { open in
            ReaderScreen(book: open.book, source: open.source, options: open.options, defaults: model.readerDefaults, handOff: open.handOff, intro: open.intro, bookmarks: open.bookmarks)
                .toggleStyle(MonoToggleStyle())
        }
        .sheet(item: $model.bookInfo) { ref in
            BookInfoView(bookId: ref.id)
                .toggleStyle(MonoToggleStyle())
        }
        .sheet(item: $model.tagEditor) { request in
            TagEditorView(bookIds: request.ids)
        }
        .sheet(item: $model.dataEditor) { request in
            BookDataEditorView(bookIds: request.ids, seriesName: request.seriesName)
                .toggleStyle(MonoToggleStyle())
        }
        .fullScreenCover(item: $model.coverEditor) { request in
            CoverEditorView(book: request.book, initialEdit: request.initialEdit)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .environment(\.coverStyle, CoverStyle(shape: coverShape, shadowStrength: coverShadow, shadowDirection: shadowDirection, roundedCorners: roundedCorners))
        .environment(\.coverInfo, coverInfo.value)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Comics Folder", systemImage: "books.vertical")
        } description: {
            Text("Pick the iCloud Drive folder that holds your comics, such as iCloud Drive › Comics. Books stay where they are; nothing in the folder is changed.")
        } actions: {
            Button { showPicker = true } label: {
                // Inverse text on the black or white accent glass (#55).
                Text("Choose Folder…").foregroundStyle(Color.onAccent)
            }
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
                // Inverse text on the black or white accent glass (#55).
                .foregroundStyle(Color.onAccent)
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
