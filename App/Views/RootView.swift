import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.coverShape) private var coverShape: CoverShape = .comic
    @AppStorage(SettingsKeys.coverShadow) private var coverShadow: Double = CoverStyle.defaultShadowStrength
    @AppStorage(SettingsKeys.coverShadowDirection) private var shadowDirection: CoverShadowDirection = .around
    @AppStorage(SettingsKeys.roundedCorners) private var roundedCorners = true
    var coverInfo = CoverInfoSettings()
    /// Whether the sidebar shows. The toolbar's sidebar button and the swipes both change it.
    @State private var columns: NavigationSplitViewVisibility = .automatic

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
            case .needsFolder:
                WelcomeView()
            case .ready:
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        // One fixed width, so a sideways drag no longer resizes the sidebar (#56).
                        .navigationSplitViewColumnWidth(SidebarSwipe.width)
                        // Swipe left on the sidebar to hide it, like the sidebar button.
                        .simultaneousGesture(SidebarSwipe.gesture(.left) { setSidebar(shown: false) })
                } detail: {
                    NavigationStack(path: $model.libraryPath) {
                        Group {
                            switch model.selection ?? .all {
                            case .series: SeriesGridView()
                            case .folders: FolderBrowserView()
                            case let item: LibraryGridView(item: item)
                            }
                        }
                        .navigationDestination(for: SidebarItem.self) { LibraryGridView(item: $0) }
                    }
                    // Start from the top of the stack when another sidebar item is picked.
                    .id(model.selection)
                    .overlay(alignment: .bottomTrailing) { ResumeButton() }
                    // With the sidebar hidden, swipe right from the left edge to bring it back.
                    // Not inside a folder or series, where that edge swipe goes back instead.
                    .overlay(alignment: .leading) {
                        if columns == .detailOnly, model.libraryPath.isEmpty {
                            Color.clear
                                .frame(width: SidebarSwipe.edgeWidth)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(SidebarSwipe.gesture(.right) { setSidebar(shown: true) })
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $model.openBook) { open in
            ReaderScreen(book: open.book, source: open.source, options: open.options, defaults: model.readerDefaults, handOff: open.handOff, intro: open.intro)
        }
        .sheet(item: $model.bookInfo) { ref in
            BookInfoView(bookId: ref.id)
        }
        .sheet(item: $model.tagEditor) { ref in
            TagEditorView(bookId: ref.id)
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
        .onChange(of: coverInfo.value.needsFileMetadata, initial: true) { _, needed in
            model.wantsFileMetadata = needed
        }
    }
}

extension RootView {
    private func setSidebar(shown: Bool) {
        let target: NavigationSplitViewVisibility = shown ? .all : .detailOnly
        guard columns != target else { return }
        withAnimation(.snappy(duration: 0.3)) { columns = target }
    }
}

/// The sideways swipes that hide and show the library sidebar (#56).
enum SidebarSwipe {
    enum Direction { case left, right }

    /// The sidebar's fixed width, about the system default.
    static let width: CGFloat = 320
    /// How far in from the library's left edge a swipe to show the sidebar can start.
    static let edgeWidth: CGFloat = 24

    /// A mostly sideways swipe of at least 60 points in `direction`. Vertical drags (scrolling)
    /// and short ones do nothing.
    static func gesture(_ direction: Direction, action: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) >= 60, abs(dx) > abs(dy) * 1.5 else { return }
                if (direction == .left && dx < 0) || (direction == .right && dx > 0) { action() }
            }
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
