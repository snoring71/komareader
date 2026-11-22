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
                // Here as in the reader's Page Layout panel (#94).
                Picker("Binding Shadow", selection: Binding(
                    get: { BindingShadowStrength.nearest(defaults.bindingShadow) },
                    set: { defaults.bindingShadow = $0.rawValue }
                )) {
                    ForEach(BindingShadowStrength.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Page Layout")
            } footer: {
                Text("Split Double Pages shows an image that holds two pages as two separate pages, in reading order. With Two Pages, the halves still share the screen. Binding Shadow darkens the middle of two-page spreads, like the fold of a printed book.")
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
            } header: {
                Text("Appearance")
            } footer: {
                Text("Match Page fills the space around the page with the colour at its edges.")
            }

            Section {
                Toggle("Auto-Fix Scans", isOn: $defaults.autoFix)
                slider("Brightness", value: $defaults.brightness, in: -1...1)
                slider("Contrast", value: $defaults.contrast, in: -1...1)
                slider("Gamma", value: $defaults.gamma, in: -1...1)
                slider("Saturation", value: $defaults.saturation, in: -1...1)
                Toggle("Black and White", isOn: $defaults.blackAndWhite)
            } header: {
                Text("Image Adjustments")
            } footer: {
                Text("Auto-Fix sets each page's white and black from the page itself, so yellowed paper turns white and faded ink black.")
            }

            Section {
                slider("Sharpness", value: $defaults.sharpness, in: 0...1)
                slider("Descreen", value: $defaults.descreen, in: 0...1)
                Toggle("Sharper Scaling", isOn: $defaults.sharperScaling)
                Toggle("Auto Trim Margins", isOn: $defaults.autoTrim)
                Toggle("Keep Color Pages", isOn: $defaults.keepColorPages)
            } header: {
                Text("Scans")
            } footer: {
                Text("Descreen softens printing dots and JPEG blocks. Sharper Scaling resizes pages to the screen with Lanczos. Auto Trim cuts each page's plain border as it loads, unless the book has its own crop. Keep Color Pages leaves colour pages alone under Black and White, Auto-Fix and Sepia.")
            }

            Section {
                Picker("Night Mode", selection: $defaults.nightMode) {
                    ForEach(ReaderOptions.NightMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Only in Dark Mode", isOn: $defaults.nightOnlyInDark)
                    .disabled(defaults.nightMode == .off)
            } header: {
                Text("Night")
            }

            Section {
                Picker("Paper", selection: $defaults.paperStock) {
                    ForEach(ReaderOptions.PaperStock.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                slider("Paper Grain", value: $defaults.paperGrain, in: 0...1)
                slider("Paper Tone", value: $defaults.paperTint, in: 0...1)
            } header: {
                Text("Paper")
            } footer: {
                Text(defaults.paperStock.note + " Off by default.")
            }

            Section {
                Text("To make one book's settings the defaults, open it and choose Use as Defaults for All Books under ••• in the reader's menu bar. Reset to Defaults there makes a book follow these again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Book Defaults")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue == 0 ? "Off" : "\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = abs($0) < 0.03 ? 0 : ($0 * 100).rounded() / 100 }
            ), in: range)
        }
    }

}
