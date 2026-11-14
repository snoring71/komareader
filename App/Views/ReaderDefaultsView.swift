import ComicCore
import SwiftUI

/// Settings › Book Defaults: the reader settings every book starts with. A setting changed
/// while reading a book applies to that book only.
struct ReaderDefaultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var defaults = model.readerDefaults
        Form {
            Section {
                Picker("Reading Direction", selection: $defaults.direction) {
                    ForEach([ReaderOptions.Direction.leftToRight, .rightToLeft], id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Fit", selection: $defaults.fit) {
                    ForEach(ReaderOptions.Fit.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("In Portrait", selection: $defaults.portraitLayout) {
                    ForEach(ReaderOptions.PageLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("In Landscape", selection: $defaults.landscapeLayout) {
                    ForEach(ReaderOptions.PageLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Split Double Pages", isOn: $defaults.splitDoublePages)
            } header: {
                Text("Page Layout")
            } footer: {
                Text("Split Double Pages shows an image that holds two pages as two separate pages, in reading order. With Two Pages, the halves still share the screen.")
            }

            Section {
                Picker("Background", selection: Binding(
                    get: { defaults.background.choice },
                    set: { choice in
                        switch choice {
                        case .black: defaults.background = .black
                        case .gray: defaults.background = .gray
                        case .white: defaults.background = .white
                        case .dynamic: defaults.background = .dynamic
                        case .custom:
                            if case .custom = defaults.background { return }
                            defaults.background = .fromRGB(red: 0.15, green: 0.15, blue: 0.15)
                        }
                    }
                )) {
                    ForEach(ReaderOptions.Background.Choice.allCases) { Text($0.title).tag($0) }
                }
                if case .custom = defaults.background {
                    ColorPicker("Custom Color", selection: Binding(
                        get: { Color(uiColor: defaults.background.uiColor ?? .black) },
                        set: { defaults.background = ReaderOptions.Background($0) }
                    ), supportsOpacity: false)
                }
                Picker("Binding Shadow", selection: Binding(
                    get: { BindingShadowStrength.nearest(defaults.bindingShadow) },
                    set: { defaults.bindingShadow = $0.rawValue }
                )) {
                    ForEach(BindingShadowStrength.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Match Page fills the space around the page with the colour at its edges. Binding Shadow darkens the middle of two-page spreads, like the fold of a printed book.")
            }

            Section {
                Text("To make one book's settings the defaults, open it and choose Use as Defaults for All Books in the reader's settings menu. Reset to Defaults there makes a book follow these again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Book Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }
}
