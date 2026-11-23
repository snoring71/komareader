import ArchiveKit
import ComicCore
import LibraryKit
import SwiftUI

/// Full-bleed reader with floating Liquid Glass controls. A tap in the middle hides them.
struct ReaderScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shelfZoomClose) private var shelfZoomClose
    @Environment(\.coverStyle) private var coverStyle
    @State private var state: ReaderState
    @State private var scrubPage: Double = 0
    @State private var isScrubbing = false
    @State private var scrubThumbnail: UIImage?
    @State private var showInfo = false
    @State private var showCrop = false
    /// The book's cover on its gradient (see `CoverIntro`), if it has one.
    @State private var cover: CoverIntro?
    /// The cover is showing over the pages: when the book opens, or from the page bar.
    @State private var showingCover = false
    /// The cover stays until the reader moves on (a first open, or chosen from the page bar);
    /// otherwise it shows for a moment while the pages load.
    @State private var coverWaits = false
    /// Fading out after a swipe up, before the reader goes away.
    @State private var closing = false
    /// The status bar hides once the reader has finished opening, and shows again before it
    /// closes: the library behind lays itself out around the status bar, so hiding it while
    /// the library shows (as the cover zooms in or out) made the whole grid jump.
    @State private var hidesStatusBar = false
    /// A newer position from another device, until the reader jumps there or says no.
    @State private var handOff: AppModel.HandOff?
    /// A Read book was turned off its last page: asks whether to start reading it again.
    @State private var askingRestart = false
    /// Asked once per opening, so a No isn't asked again on every page.
    @State private var restartAsked = false
    /// Shows "Copied" on the Select Text bar for a moment after Copy All.
    @State private var copiedText = false

    init(book: Book, source: BookSource, options: ReaderOptions, defaults: ReaderDefaults,
         handOff: AppModel.HandOff? = nil, intro: CoverIntro? = nil, bookmarks: [Int]? = nil) {
        _state = State(initialValue: ReaderState(book: book, source: source, options: options, defaults: defaults, bookmarks: bookmarks))
        _handOff = State(initialValue: handOff)
        _cover = State(initialValue: intro)
        _showingCover = State(initialValue: intro != nil && CoverIntro.isEnabled)
        _coverWaits = State(initialValue: intro?.waits ?? false)
    }

    /// The live row for this book (Favorite and Bookmarked can change while reading).
    private var liveBook: Book { model.books.first { $0.id == state.book.id } ?? state.book }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: state.background.uiColor ?? .black).ignoresSafeArea()
                PageViewer(state: state)
                    .ignoresSafeArea()
                // Each overlay has a fixed zIndex: without one, a view leaving a ZStack can drop
                // behind the pages and vanish instead of fading out.
                if showingCover, let cover {
                    CoverIntroView(
                        intro: cover, waits: coverWaits, rightToLeft: state.rightToLeft,
                        onForward: { endIntro() },
                        onToggleChrome: { state.showChrome.toggle() },
                        onClose: { state.closeRequested = true }
                    )
                    // A book read before: the cover grows gently into the page as it fades.
                    .transition(coverWaits ? .opacity : .opacity.combined(with: .scale(scale: 1.06)))
                    .zIndex(1)
                }
                if state.showChrome {
                    chrome
                        .transition(.opacity)
                        .zIndex(2)
                }
                if state.selectingText && !isScrubbing {
                    textBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(3)
                }
                if askingRestart {
                    restartBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(5)
                }
                if let handOff {
                    handOffBanner(handOff)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(4)
                }
            }
            .onAppear { state.setLandscape(geo.size.width > geo.size.height) }
            .onChange(of: geo.size) { _, size in state.setLandscape(size.width > size.height) }
        }
        .opacity(closing ? 0 : 1)
        .scaleEffect(closing ? 0.96 : 1)
        // Clear behind the reader, so the library shows through as it fades after a swipe up.
        .presentationBackground(.clear)
        .animation(.easeInOut(duration: 0.25), value: state.showChrome)
        .animation(.easeInOut(duration: 0.25), value: handOff)
        .animation(.easeInOut(duration: 0.25), value: askingRestart)
        .animation(.easeInOut(duration: 0.2), value: state.selectingText)
        .animation(.easeInOut(duration: 0.2), value: state.textStatus)
        .sheet(isPresented: $showInfo) {
            BookInfoView(bookId: state.book.id, source: state.source)
                .toggleStyle(MonoToggleStyle())
        }
        .sheet(isPresented: $showCrop) {
            PageCropView(state: state)
        }
        // Reading direction changed in Book Info while the book is open.
        .onChange(of: liveBook.direction) { _, direction in
            state.adoptDirection(direction.flatMap(ReaderOptions.Direction.init(rawValue:)))
        }
        .statusBarHidden(hidesStatusBar)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            if !closing { hidesStatusBar = true }
        }
        .persistentSystemOverlays(state.showChrome ? .automatic : .hidden)
        .onAppear {
            let bookId = state.book.id, count = state.pageCount
            let appModel = model
            let handOffPrompt = $handOff
            let restartPrompt = $askingRestart, restartWasAsked = $restartAsked
            let wasFinished = state.book.finished, readerState = state
            let coverShown = $showingCover
            if let cover {
                let style = coverStyle, readerState = state
                state.makeCoverPage = { [weak readerState] in
                    let page = UIHostingController(rootView: AnyView(
                        CoverIntroView(intro: cover, waits: false, rightToLeft: readerState?.rightToLeft ?? false,
                                       onForward: {}, onToggleChrome: {}, onClose: {}, identifier: "reader-cover-page")
                            .environment(\.coverStyle, style)
                    ))
                    page.safeAreaRegions = []
                    page.view.backgroundColor = .clear
                    return page
                }
            }
            // After the last page: the next book where this one was opened from (#83).
            if let next = model.nextBook(after: bookId) {
                let style = coverStyle
                let coverURL = model.thumbnails[next.book.id], revision = model.coverRevision[next.book.id] ?? 0
                state.makeEndPage = { [weak readerState] in
                    let page = UIHostingController(rootView: AnyView(
                        NextBookPage(next: next, coverURL: coverURL, coverRevision: revision,
                                     onBack: { readerState?.leaveEndPage() })
                            .environment(\.coverStyle, style)
                            .environment(appModel)
                    ))
                    page.safeAreaRegions = []
                    page.view.backgroundColor = .clear
                    return page
                }
            }
            state.onOptionsChange = { [weak appModel] options in
                appModel?.saveReaderOptions(bookId: bookId, options: options)
            }
            state.onBookmarksChange = { [weak appModel] pages in
                appModel?.savePageBookmarks(bookId: bookId, pages: pages)
            }
            state.onPageChange = { [weak appModel] page, finished in
                appModel?.saveProgress(bookId: bookId, page: page, pageCount: count, finished: finished)
                // Turning the page answers the hand-off question too.
                if handOffPrompt.wrappedValue != nil { handOffPrompt.wrappedValue = nil }
                // A Read book, turned to any page but the last: ask whether to read it again.
                if wasFinished, !restartWasAsked.wrappedValue, !readerState.currentPages.contains(count - 1) {
                    restartWasAsked.wrappedValue = true
                    restartPrompt.wrappedValue = true
                }
                // Moving to another page (the scrubber, a hand-off jump) moves past the cover
                // too. Only the reader's own moves count: the layout settling as the book opens
                // (page sizes read, the screen's orientation) also renumbers the screens, and
                // ending the cover then made it show for less time on some books than others.
                if coverShown.wrappedValue {
                    withAnimation(.easeOut(duration: 0.55)) { coverShown.wrappedValue = false }
                }
            }
            scrubPage = Double(state.currentPage)
            // Record that the book was opened, so it shows under Continue Reading. Not while
            // the cover shows: opening a book to its cover and closing it doesn't count as
            // reading (see onDisappear).
            if !showingCover {
                model.saveProgress(bookId: bookId, page: state.currentPage, pageCount: count, finished: state.currentPages.contains(count - 1) && count > 1)
            }
            state.prefetch()
        }
        .onDisappear {
            state.cancel()
            // Closing anywhere but the cover counts as reading, even on the first page. From
            // the cover nothing is saved: an unread book stays unread, and a book read before
            // keeps the page it was left on.
            if !showingCover {
                model.saveProgress(bookId: state.book.id, page: state.currentPage, pageCount: state.pageCount,
                                   finished: state.currentPages.contains(state.pageCount - 1) && state.pageCount > 1,
                                   immediately: true)
            }
        }
        .onChange(of: state.currentSpread) { _, _ in
            if !isScrubbing { scrubPage = Double(state.currentPage) }
        }
        .onChange(of: state.closeRequested) { _, requested in
            if requested { closeBySwipe() }
        }
        // Back from the first page, by a tap or a swipe: the pager has turned to its copy of
        // the cover, and the reader's cover replaces it at once. Fading it in over an
        // identical copy doubled the shadows and darkened the cover for a moment.
        .onChange(of: state.coverRequested) { _, requested in
            guard requested else { return }
            state.coverRequested = false
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                coverWaits = true
                state.showChrome = false
                showingCover = true
            }
        }
        .task {
            // A book read before: show the cover for a moment while the pages load beneath it.
            guard showingCover, !coverWaits else { return }
            try? await Task.sleep(for: .milliseconds(550))
            endIntro()
        }
        .task(id: isScrubbing ? Int(scrubPage) : -1) {
            guard isScrubbing else { scrubThumbnail = nil; return }
            let page = Int(scrubPage)
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return }
            if let image = await state.thumbnail(for: page), !Task.isCancelled { scrubThumbnail = image }
        }
    }

    private func endIntro() {
        guard showingCover else { return }
        withAnimation(.easeOut(duration: 0.55)) { showingCover = false }
    }

    /// Back to the cover, from the page bar. It stays until the reader moves on.
    private func showCover() {
        coverWaits = true
        state.showChrome = false
        withAnimation(.easeInOut(duration: 0.4)) { showingCover = true }
    }

    /// The close button: the status bar comes back first, so the library is already laid out
    /// for it when it shows behind the closing reader.
    private func close() {
        guard !closing else { return }
        hidesStatusBar = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if let shelfZoomClose { shelfZoomClose() } else { dismiss() }
        }
    }

    /// After a swipe up: the page has flown up; fade the reader to the library and close.
    private func closeBySwipe() {
        guard !closing else { return }
        hidesStatusBar = false
        // Opened from a cover: back onto it, from where the page flew up to.
        if let shelfZoomClose {
            shelfZoomClose()
            return
        }
        withAnimation(.easeOut(duration: 0.25)) { closing = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            // Already faded: close without the slide-down of the close button.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.openBook = nil }
        }
    }

    /// Asks whether a Read book is being read again. Yes makes it Reading from this page
    /// (reaching the last page makes it Read again); No leaves it Read.
    private var restartBanner: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.body.weight(.semibold))
                Text("Reset reading progress?")
                    .font(.subheadline.weight(.medium))
                Button {
                    askingRestart = false
                    model.saveProgress(bookId: state.book.id, page: state.currentPage, pageCount: state.pageCount,
                                       finished: false, keepFinished: false)
                } label: {
                    // Inverse text on the black or white accent glass (#55).
                    Text("Yes").foregroundStyle(Color.onAccent)
                }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("restart-yes")
                Button("No, Keep as Read") { askingRestart = false }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("restart-no")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
            // Below the menu bar while the controls show.
            .padding(.top, state.showChrome ? 140 : 70)
            Spacer()
        }
    }

    private func handOffBanner(_ handOff: AppModel.HandOff) -> some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.semibold))
                Text("Jump to page \(handOff.page + 1) from \(handOff.deviceName)?")
                    .font(.subheadline.weight(.medium))
                Button {
                    self.handOff = nil
                    state.jump(toPage: handOff.page)
                } label: {
                    // Inverse text on the black or white accent glass (#55).
                    Text("Jump").foregroundStyle(Color.onAccent)
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
            // Below the menu bar while the controls show.
            .padding(.top, state.showChrome ? 140 : 70)
            Spacer()
        }
    }

    private var chrome: some View {
        GlassEffectContainer(spacing: 16) {
            VStack {
                // Apart enough that the glass of the title and the bar don't run together.
                VStack(spacing: 22) {
                    topBar
                    ReaderMenuBar(items: ReaderBarItem.items(state: state, book: liveBook, model: model) {
                        showCrop = true
                    })
                }
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
                close()
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

            // Acts on the page on screen, like Select Text beside it (#92).
            SharePageButton(state: state)

            if PageTextAnalyzer.isSupported {
                // Lit while Select Text is on.
                if state.selectingText {
                    selectTextButton.buttonStyle(.glassProminent).foregroundStyle(Color.onAccent)
                } else {
                    selectTextButton.buttonStyle(.glass)
                }
            }

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

    private var selectTextButton: some View {
        Button {
            state.selectingText.toggle()
        } label: {
            Image(systemName: "text.viewfinder").font(.body.weight(.semibold)).frame(width: 28, height: 28)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(state.selectingText ? "Stop Selecting Text" : "Select Text")
        .accessibilityIdentifier("reader-select-text")
    }

    /// While Select Text is on: what Live Text found, Copy All, and Done.
    private var textBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Group {
                    switch state.textStatus {
                    case .idle, .searching:
                        ProgressView().controlSize(.small)
                        Text("Finding text…")
                    case .found:
                        Image(systemName: "text.viewfinder")
                        Text(copiedText ? "Copied" : "Touch and hold text to select it")
                    case .none:
                        Image(systemName: "text.badge.xmark")
                        Text("No text found on this page")
                    case .partial:
                        Image(systemName: "text.badge.xmark")
                        Text(copiedText ? "Copied" : "No text found on one page")
                    case .failed:
                        Image(systemName: "exclamationmark.triangle")
                        Text(copiedText ? "Copied" : "A page couldn’t be read")
                    }
                }
                .font(.subheadline.weight(.medium))
                if [ReaderState.TextStatus.failed, .none, .partial].contains(state.textStatus) {
                    Button("Try Again", systemImage: "arrow.clockwise") { state.retryText() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("reader-text-retry")
                }
                Button("Copy All", systemImage: "doc.on.doc") {
                    let text = state.currentTranscript()
                    guard !text.isEmpty else { return }
                    UIPasteboard.general.string = text
                    copiedText = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedText = false
                    }
                }
                .buttonStyle(.glass)
                .disabled(![ReaderState.TextStatus.found, .partial, .failed].contains(state.textStatus))
                .accessibilityIdentifier("reader-copy-text")
                Button { state.selectingText = false } label: {
                    Text("Done").foregroundStyle(Color.onAccent)
                }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("reader-text-done")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
            // Above the page bar when the controls show.
            .padding(.bottom, state.showChrome ? 88 : 24)
        }
        .animation(.easeInOut(duration: 0.2), value: state.showChrome)
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

    /// The cover, as when the book opened. It sits at the start of the page bar: the left
    /// for left-to-right books, the right for manga, where the bar runs the other way.
    @ViewBuilder
    private var coverButton: some View {
        if let cover {
            Button(action: showCover) {
                Image(uiImage: cover.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.2)))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Cover")
            .accessibilityIdentifier("reader-show-cover")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if !state.rightToLeft { coverButton }
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
                // Bookmarked pages, as small marks above the track.
                .overlay(alignment: .top) {
                    BookmarkTicks(pages: state.bookmarks, pageCount: state.pageCount, rightToLeft: state.rightToLeft)
                }
            }
            if state.rightToLeft { coverButton }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(in: .capsule)
        .frame(maxWidth: 720)
    }
}

/// Small orange marks above the page scrubber at the bookmarked pages.
private struct BookmarkTicks: View {
    let pages: [Int]
    let pageCount: Int
    let rightToLeft: Bool
    /// How far the slider's track starts in from its ends (about half its thumb).
    private let inset: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let track = max(0, geo.size.width - inset * 2)
            ForEach(pages, id: \.self) { page in
                let fraction = pageCount > 1 ? CGFloat(page) / CGFloat(pageCount - 1) : 0
                Capsule()
                    .fill(Color.orange)
                    .frame(width: 3, height: 8)
                    .position(x: inset + track * (rightToLeft ? 1 - fraction : fraction), y: -4)
            }
        }
        .frame(height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
