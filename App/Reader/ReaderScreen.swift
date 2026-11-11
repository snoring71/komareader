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

    init(book: Book, source: BookSource) {
        _state = State(initialValue: ReaderState(book: book, source: source))
    }

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
            }
            .onAppear { state.setLandscape(geo.size.width > geo.size.height) }
            .onChange(of: geo.size) { _, size in state.setLandscape(size.width > size.height) }
        }
        .animation(.easeInOut(duration: 0.2), value: state.showChrome)
        .statusBarHidden(true)
        .persistentSystemOverlays(state.showChrome ? .automatic : .hidden)
        .onAppear {
            let bookId = state.book.id, count = state.pageCount
            let appModel = model
            state.onPageChange = { [weak appModel] page, finished in
                appModel?.saveProgress(bookId: bookId, page: page, pageCount: count, finished: finished)
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
    }

    private var chrome: some View {
        GlassEffectContainer(spacing: 16) {
            VStack {
                topBar
                Spacer()
                bottomBar
            }
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
            } label: {
                Image(systemName: "textformat.size").font(.body.weight(.semibold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Reader Settings")
        }
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
