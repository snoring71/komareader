import ComicCore
import LibraryKit
import SwiftUI

/// The reader's settings, in a popover from the Aa button. Every change applies to this book
/// only; Use as Defaults hands the book's settings on to every book.
struct ReaderSettingsPanel: View {
    let state: ReaderState
    let book: Book
    let onCrop: () -> Void
    @Environment(AppModel.self) private var model

    /// The live row, so Favorite and Bookmarked update while the panel is open.
    private var liveBook: Book { model.books.first { $0.id == book.id } ?? book }

    /// The custom background colour while it is being picked; saved once it settles.
    @State private var pickedColor: Color?

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    ChoiceBar<ReaderOptions.Direction>([(.leftToRight, "Left to Right"), (.rightToLeft, "Right to Left")],
                              selection: setting(\.direction) { $0.direction = $1 })
                        .accessibilityIdentifier("settings-direction")
                    Picker("Fit", selection: setting(\.fit) { $0.fit = $1 }) {
                        ForEach(ReaderOptions.Fit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }

                Section("Page Layout") {
                    LabeledContent("Portrait") {
                        layoutPicker(setting(\.portraitLayout) { $0.portraitLayout = $1 })
                    }
                    LabeledContent("Landscape") {
                        layoutPicker(setting(\.landscapeLayout) { $0.landscapeLayout = $1 })
                    }
                    Toggle("Split Double Pages", isOn: setting(\.splitDoublePages) { $0.splitDoublePages = $1 })
                    Button(state.crop == nil ? "Crop Pages…" : "Edit Page Crop…", systemImage: "crop", action: onCrop)
                        .accessibilityIdentifier("reader-crop")
                }

                Section("Appearance") {
                    Picker("Background", selection: Binding(
                        get: { state.background.choice },
                        set: { choice in
                            switch choice {
                            case .black: state.change { $0.background = .black }
                            case .gray: state.change { $0.background = .gray }
                            case .white: state.change { $0.background = .white }
                            case .dynamic: state.change { $0.background = .dynamic }
                            case .custom:
                                if case .custom = state.background { return }
                                state.change { $0.background = .fromRGB(red: 0.15, green: 0.15, blue: 0.15) }
                            }
                        }
                    )) {
                        ForEach(ReaderOptions.Background.Choice.allCases) { Text($0.title).tag($0) }
                    }
                    if case .custom = state.background {
                        ColorPicker("Custom Color", selection: Binding(
                            get: { pickedColor ?? Color(uiColor: state.background.uiColor ?? .black) },
                            set: { pickedColor = $0 }
                        ), supportsOpacity: false)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Binding Shadow")
                        ChoiceBar<BindingShadowStrength>(BindingShadowStrength.allCases.map { ($0, $0.title) }, selection: Binding(
                            get: { BindingShadowStrength.nearest(state.bindingShadow) },
                            set: { strength in state.change { $0.bindingShadow = strength.rawValue } }
                        ))
                    }
                }

                Section {
                    Button("Use as Defaults for All Books", systemImage: "checkmark.circle") { state.useAsDefaults() }
                    Button("Reset to Defaults", systemImage: "arrow.uturn.backward") { state.resetToDefaults() }
                        .disabled(!state.hasOwnSettings)
                } footer: {
                    Text(state.hasOwnSettings ? "This book has its own settings." : "This book follows the defaults in Settings › Book Defaults.")
                }

                Section {
                    let book = liveBook
                    Toggle(isOn: Binding(get: { book.favorite }, set: { model.setFavorite(book, $0) })) {
                        Label("Favorite", systemImage: "heart")
                    }
                    Toggle(isOn: Binding(get: { book.bookmarked }, set: { model.setBookmarked(book, $0) })) {
                        Label("Bookmarked", systemImage: "bookmark")
                    }
                }
            }
            .navigationTitle("Reader Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("reader-settings-panel")
        // The colour picker reports every step of a drag; save the colour once it rests.
        .task(id: pickedColor.map { ReaderOptions.Background($0).code }) {
            guard let pickedColor else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            state.change { $0.background = ReaderOptions.Background(pickedColor) }
        }
    }

    private func layoutPicker(_ selection: Binding<ReaderOptions.PageLayout>) -> some View {
        ChoiceBar<ReaderOptions.PageLayout>(ReaderOptions.PageLayout.allCases.map { ($0, $0.title) }, selection: selection)
            .frame(width: 230)
    }

    /// A binding to one setting as the reader uses it; setting it makes it this book's own.
    private func setting<Value>(_ current: KeyPath<ReaderState, Value>, _ set: @escaping (inout ReaderOptions, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { state[keyPath: current] },
            set: { value in state.change { set(&$0, value) } }
        )
    }
}
