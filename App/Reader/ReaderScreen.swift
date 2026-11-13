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
    @State private var showColorPicker = false
    /// A newer position from another device, until the reader jumps there or says no.
    @State private var handOff: AppModel.HandOff?

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
        .sheet(isPresented: $showCrop) {
            PageCropView(state: state)
        }
        .sheet(isPresented: $showColorPicker) {
            BackgroundColorSheet(color: customColor) { color in
                state.change { $0.background = ReaderOptions.Background(color) }
            }
            .presentationDetents([.height(220)])
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

            Menu {
                readerSettingsMenu
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

    // MARK: Reader settings

    /// The book's settings. Each change applies to this book only; Use as Defaults hands them on.
    @ViewBuilder private var readerSettingsMenu: some View {
        Picker("Reading Direction", selection: setting(\.direction) { $0.direction = $1 }) {
            ForEach([ReaderOptions.Direction.leftToRight, .rightToLeft], id: \.self) {
                Label($0.title, systemImage: $0.systemImage).tag($0)
            }
        }
        Menu {
            Picker("In Portrait", selection: setting(\.portraitLayout) { $0.portraitLayout = $1 }) {
                ForEach(ReaderOptions.PageLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("In Landscape", selection: setting(\.landscapeLayout) { $0.landscapeLayout = $1 }) {
                ForEach(ReaderOptions.PageLayout.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Page Layout", systemImage: "book.pages")
        }
        Picker("Fit", selection: setting(\.fit) { $0.fit = $1 }) {
            ForEach(ReaderOptions.Fit.allCases, id: \.self) { Label($0.title, systemImage: $0.systemImage).tag($0) }
        }
        Section {
            Picker(selection: Binding(
                get: { state.background.choice },
                set: { choice in
                    switch choice {
                    case .black: state.change { $0.background = .black }
                    case .gray: state.change { $0.background = .gray }
                    case .white: state.change { $0.background = .white }
                    case .dynamic: state.change { $0.background = .dynamic }
                    case .custom: showColorPicker = true
                    }
                }
            )) {
                ForEach(ReaderOptions.Background.Choice.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Background", systemImage: "paintpalette")
            }
            .pickerStyle(.menu)
            Picker(selection: Binding(
                get: { BindingShadowStrength.nearest(state.bindingShadow) },
                set: { strength in state.change { $0.bindingShadow = strength.rawValue } }
            )) {
                ForEach(BindingShadowStrength.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Binding Shadow", systemImage: "book")
            }
            .pickerStyle(.menu)
            Toggle(isOn: setting(\.splitDoublePages) { $0.splitDoublePages = $1 }) {
                Label("Split Double Pages", systemImage: "rectangle.split.2x1")
            }
            Button(state.crop == nil ? "Crop Pages…" : "Edit Page Crop…", systemImage: "crop") { showCrop = true }
                .accessibilityIdentifier("reader-crop")
        }
        Section {
            Button("Use as Defaults for All Books", systemImage: "checkmark.circle") { state.useAsDefaults() }
            Button("Reset to Defaults", systemImage: "arrow.uturn.backward") { state.resetToDefaults() }
                .disabled(!state.hasOwnSettings)
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
    }

    /// A binding to one setting as the reader uses it; setting it makes it this book's own.
    private func setting<Value>(_ current: KeyPath<ReaderState, Value>, _ set: @escaping (inout ReaderOptions, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { state[keyPath: current] },
            set: { value in state.change { set(&$0, value) } }
        )
    }

    /// The colour the custom background picker starts from.
    private var customColor: Color {
        Color(uiColor: state.background.uiColor ?? UIColor(white: 0.15, alpha: 1))
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

/// Picks a custom background colour for the reader; it is applied when the sheet closes.
struct BackgroundColorSheet: View {
    @State private var color: Color
    let onDone: (Color) -> Void
    @Environment(\.dismiss) private var dismiss

    init(color: Color, onDone: @escaping (Color) -> Void) {
        _color = State(initialValue: color)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                ColorPicker("Background Color", selection: $color, supportsOpacity: false)
            }
            .navigationTitle("Custom Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(color)
                        dismiss()
                    }
                }
            }
        }
    }
}
