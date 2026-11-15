import ArchiveKit
import ComicCore
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
    @State private var showCrop = false
    @State private var showSettings = false
    /// A newer position from another device, until the reader jumps there or says no.
    @State private var handOff: AppModel.HandOff?
    /// Shows "Copied" on the Select Text bar for a moment after Copy All.
    @State private var copiedText = false

    init(book: Book, source: BookSource, options: ReaderOptions, defaults: ReaderDefaults, handOff: AppModel.HandOff? = nil) {
        _state = State(initialValue: ReaderState(book: book, source: source, options: options, defaults: defaults))
        _handOff = State(initialValue: handOff)
    }

    /// The live row for this book (Favorite and Bookmarked can change while reading).
    private var liveBook: Book { model.books.first { $0.id == state.book.id } ?? state.book }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: state.background.uiColor ?? .black).ignoresSafeArea()
                PageViewer(state: state)
                    .ignoresSafeArea()
                if state.showChrome {
                    chrome
                        .transition(.opacity)
                }
                if state.selectingText && !isScrubbing {
                    textBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(.easeInOut(duration: 0.2), value: state.selectingText)
        .animation(.easeInOut(duration: 0.2), value: state.textStatus)
        .sheet(isPresented: $showInfo) {
            BookInfoView(bookId: state.book.id, source: state.source)
        }
        .sheet(isPresented: $showCrop) {
            PageCropView(state: state)
        }
        // Reading direction changed in Book Info while the book is open.
        .onChange(of: liveBook.direction) { _, direction in
            state.adoptDirection(direction.flatMap(ReaderOptions.Direction.init(rawValue:)))
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(state.showChrome ? .automatic : .hidden)
        .onAppear {
            let bookId = state.book.id, count = state.pageCount
            let appModel = model
            let handOffPrompt = $handOff
            state.onOptionsChange = { [weak appModel] options in
                appModel?.saveReaderOptions(bookId: bookId, options: options)
            }
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

            if PageTextAnalyzer.isSupported {
                // Lit while Select Text is on.
                if state.selectingText {
                    selectTextButton.buttonStyle(.glassProminent)
                } else {
                    selectTextButton.buttonStyle(.glass)
                }
            }

            // A popover rather than a menu: with this many settings (and submenus) the menu
            // rebuilt itself under the finger and missed taps.
            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat.size").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Reader Settings")
            .accessibilityIdentifier("reader-settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                ReaderSettingsPanel(state: state, book: liveBook) {
                    showSettings = false
                    // Let the popover close before the crop editor opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showCrop = true }
                }
                .frame(idealWidth: 380, idealHeight: 640)
                .presentationCompactAdaptation(.popover)
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
                Button("Done") { state.selectingText = false }
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
