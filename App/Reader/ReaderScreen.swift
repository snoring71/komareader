import ArchiveKit
import LibraryKit
import SwiftUI

/// Full-bleed reader with floating Liquid Glass controls. A tap in the middle hides them.
struct ReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state: ReaderState
    @State private var scrubPage: Double = 0
    @State private var isScrubbing = false
    @State private var scrubThumbnail: UIImage?
    @State private var showInfo = false
    /// A newer position from another device, until the reader jumps there or says no.
    @State private var handOff: AppModel.HandOff?

    init(book: Book, source: BookSource, handOff: AppModel.HandOff? = nil) {
        _state = State(initialValue: ReaderState(book: book, source: source))
        _handOff = State(initialValue: handOff)
    }

    /// The live row for this book (Favorite and Bookmarked can change while reading).
    private var liveBook: Book { model.books.first { $0.id == state.book.id } ?? state.book }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                PageViewer(state: state)
                    .ignoresSafeArea()
                if state.showChrome {
                    chrome
                        .transition(.opacity)
                }
                if let handOff {
                    handOffBanner(handOff)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear { state.setLandscape(geo.size.width > geo.size.height) }
            .onChange(of: geo.size) { _, size in state.setLandscape(size.width > size.height) }
        }
        .animation(.easeInOut(duration: 0.2), value: state.showChrome)
        .animation(.easeInOut(duration: 0.25), value: handOff)
        .sheet(isPresented: $showInfo) {
            BookInfoView(bookId: state.book.id, source: state.source)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(state.showChrome ? .automatic : .hidden)
        .onAppear {
            let bookId = state.book.id, count = state.pageCount
            let appModel = model
            let handOffPrompt = $handOff
            state.onPageChange = { [weak appModel] page, finished in
                appModel?.saveProgress(bookId: bookId, page: page, pageCount: count, finished: finished)
                // Turning the page answers the hand-off question too.
                if handOffPrompt.wrappedValue != nil { handOffPrompt.wrappedValue = nil }
            }
            scrubPage = Double(state.currentPage)
            // Record that the book was opened, so it shows under Continue Reading.
            model.saveProgress(bookId: bookId, page: state.currentPage, pageCount: count, finished: state.currentPages.contains(count - 1) && count > 1)
            state.prefetch()
        }
        .onDisappear { state.cancel() }
        .onChange(of: state.currentSpread) { _, _ in
            if !isScrubbing { scrubPage = Double(state.currentPage) }
        }
        .task(id: isScrubbing ? Int(scrubPage) : -1) {
            guard isScrubbing else { scrubThumbnail = nil; return }
            let page = Int(scrubPage)
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            if let image = await state.thumbnail(for: page), !Task.isCancelled { scrubThumbnail = image }
        }
    }

    private func handOffBanner(_ handOff: AppModel.HandOff) -> some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                Text("Jump to page \(handOff.page + 1) from \(handOff.deviceName)?")
                    .font(.subheadline.weight(.medium))
                Button("Jump") {
                    self.handOff = nil
                    state.jump(toPage: handOff.page)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("handoff-jump")
                Button("Not Now") { self.handOff = nil }
                    .buttonStyle(.glass)
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
            .padding(.top, 70)
            Spacer()
        }
    }

    private var chrome: some View {
        GlassEffectContainer(spacing: 16) {
            VStack {
                topBar
                Spacer()
                if isScrubbing {
                    scrubPreview
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                bottomBar
            }
            .animation(.easeOut(duration: 0.15), value: isScrubbing)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("reader-close")

            Spacer(minLength: 0)
            Text(state.book.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: .capsule)
            Spacer(minLength: 0)

            Menu {
                Picker("Reading Direction", selection: Binding(
                    get: { state.rightToLeft },
                    set: { newValue in
                        state.rightToLeft = newValue
                        model.saveDirection(bookId: state.book.id, rightToLeft: newValue)
                    }
                )) {
                    Label("Left to Right", systemImage: "arrow.right").tag(false)
                    Label("Right to Left (Manga)", systemImage: "arrow.left").tag(true)
                }
                Picker("Page Layout", selection: $state.layout) {
                    ForEach(ReaderState.Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Fit", selection: $state.fit) {
                    ForEach(ReaderState.Fit.allCases) { Label($0.rawValue, systemImage: $0.systemImage).tag($0) }
                }
                Section {
                    let book = liveBook
                    Button(book.favorite ? "Remove from Favorites" : "Favorite", systemImage: book.favorite ? "heart.fill" : "heart") {
                        model.setFavorite(book, !book.favorite)
                    }
                    Button(book.bookmarked ? "Remove Bookmark" : "Bookmark", systemImage: book.bookmarked ? "bookmark.fill" : "bookmark") {
                        model.setBookmarked(book, !book.bookmarked)
                    }
                }
            } label: {
                Image(systemName: "textformat.size").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Reader Settings")
            .accessibilityIdentifier("reader-settings")

            Button {
                showInfo = true
            } label: {
                Image(systemName: "info").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Book Info")
            .accessibilityIdentifier("reader-info")
        }
    }

    /// The page under the scrubber, shown while dragging it.
    private var scrubPreview: some View {
        VStack(spacing: 6) {
            Group {
                if let scrubThumbnail {
                    Image(uiImage: scrubThumbnail).resizable().scaledToFit()
                } else {
                    Color.white.opacity(0.08).aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { ProgressView() }
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Page \(Int(scrubPage) + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .padding(10)
        .glassEffect(in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("reader-scrub-preview")
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text(isScrubbing ? "\(Int(scrubPage) + 1) of \(state.pageCount)" : state.pageLabel)
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 90)
            if state.pageCount > 1 {
                Slider(value: $scrubPage, in: 0...Double(state.pageCount - 1), step: 1) { editing in
                    isScrubbing = editing
                    if !editing { state.jump(toPage: Int(scrubPage)) }
                }
                // Manga scrubs from right to left, like the pages.
                .environment(\.layoutDirection, state.rightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityIdentifier("reader-scrubber")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
        .frame(maxWidth: 720)
    }
}
