import ComicCore
import SwiftUI

// The small panels that open from items in the reader's menu bar. Every change applies to
// this book at once and is saved as its own; Use as Defaults (under •••) hands the book's
// settings on to every book. Plain buttons and the custom ChoiceBar only: segmented pickers
// and nested menus missed taps inside popovers.

/// A titled panel of a fixed width.
private struct BarPanel<Content: View>: View {
    let title: String
    var width: CGFloat = 340
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(width: width, alignment: .leading)
    }
}

/// A caption above a control.
private struct PanelRow<Content: View>: View {
    let title: String
    var value: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            content
        }
    }
}

// MARK: - Page layout

struct PageLayoutPanel: View {
    let state: ReaderState

    var body: some View {
        BarPanel(title: "Page Layout") {
            PanelRow(title: "Portrait") {
                ChoiceBar<ReaderOptions.PageLayout>(ReaderOptions.PageLayout.allCases.map { ($0, $0.title) },
                                                    selection: setting(state, \.portraitLayout) { $0.portraitLayout = $1 })
                    .accessibilityIdentifier("settings-portrait-layout")
            }
            PanelRow(title: "Landscape") {
                ChoiceBar<ReaderOptions.PageLayout>(ReaderOptions.PageLayout.allCases.map { ($0, $0.title) },
                                                    selection: setting(state, \.landscapeLayout) { $0.landscapeLayout = $1 })
                    .accessibilityIdentifier("settings-landscape-layout")
            }
            Toggle("Split Double Pages", isOn: setting(state, \.splitDoublePages) { $0.splitDoublePages = $1 })
                .font(.subheadline.weight(.medium))
            PanelRow(title: "Binding Shadow") {
                ChoiceBar<BindingShadowStrength>(BindingShadowStrength.allCases.map { ($0, $0.title) }, selection: Binding(
                    get: { BindingShadowStrength.nearest(state.bindingShadow) },
                    set: { strength in state.change { $0.bindingShadow = strength.rawValue } }
                ))
            }
        }
        .accessibilityIdentifier("reader-layout-panel")
    }
}

// MARK: - Background

struct BackgroundPanel: View {
    let state: ReaderState
    /// The custom colour while it is being picked; saved once it settles.
    @State private var pickedColor: Color?

    var body: some View {
        BarPanel(title: "Background") {
            HStack(spacing: 0) {
                ForEach(ReaderOptions.Background.Choice.allCases) { choice in
                    swatch(choice)
                        .frame(maxWidth: .infinity)
                }
            }
            if case .custom = state.background {
                ColorPicker("Custom Color", selection: Binding(
                    get: { pickedColor ?? Color(uiColor: state.background.uiColor ?? .black) },
                    set: { pickedColor = $0 }
                ), supportsOpacity: false)
                .font(.subheadline.weight(.medium))
            }
            if state.background == .dynamic {
                Text("Match Page fills the space around the page with the colour at its edges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.background.choice)
        .accessibilityIdentifier("reader-background-panel")
        // The colour picker reports every step of a drag; save the colour once it rests.
        .task(id: pickedColor.map { ReaderOptions.Background($0).code }) {
            guard let pickedColor else { return }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            state.change { $0.background = ReaderOptions.Background(pickedColor) }
        }
    }

    private func swatch(_ choice: ReaderOptions.Background.Choice) -> some View {
        let selected = state.background.choice == choice
        return Button {
            choose(choice)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    swatchFill(choice)
                    Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1)
                }
                .frame(width: 34, height: 34)
                .padding(4)
                .overlay {
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2.5)
                        .opacity(selected ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.85)
                }
                Text(choice == .dynamic ? "Match" : choice == .custom ? "Custom" : choice.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: selected)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("background-\(choice.rawValue)")
    }

    @ViewBuilder
    private func swatchFill(_ choice: ReaderOptions.Background.Choice) -> some View {
        switch choice {
        case .black: Circle().fill(Color.black)
        case .gray: Circle().fill(Color(white: 0.5))
        case .white: Circle().fill(Color.white)
        case .dynamic:
            BackgroundIcon(background: .dynamic).scaleEffect(34.0 / 24.0)
        case .custom:
            if case .custom = state.background, let color = state.background.uiColor {
                Circle().fill(Color(uiColor: color))
            } else {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            }
        }
    }

    private func choose(_ choice: ReaderOptions.Background.Choice) {
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
}

// MARK: - Image adjustments

struct AdjustmentsPanel: View {
    let state: ReaderState

    var body: some View {
        let look = state.look
        BarPanel(title: "Image Adjustments") {
            slider("Contrast", value: \.contrast, in: -1...1, shown: signedPercent(look.contrast))
                .accessibilityIdentifier("adjust-contrast")
            slider("Sharpness", value: \.sharpness, in: 0...1, shown: percent(look.sharpness))
                .accessibilityIdentifier("adjust-sharpness")
            Divider()
            slider("Paper Grain", value: \.paperGrain, in: 0...1, shown: percent(look.paperGrain))
                .accessibilityIdentifier("adjust-grain")
            slider("Paper Tone", value: \.paperTint, in: 0...1, shown: percent(look.paperTint))
                .accessibilityIdentifier("adjust-tint")
            HStack {
                Text("Changes show as you drag. Select Text still reads the original page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Reset") {
                    state.previewLook = PageLook()
                    state.commitLook()
                }
                .buttonStyle(.bordered)
                .disabled(look.isNone)
                .accessibilityIdentifier("adjust-reset")
            }
        }
        .accessibilityIdentifier("reader-adjust-panel")
    }

    private func slider(_ title: String, value: WritableKeyPath<PageLook, Double>, in range: ClosedRange<Double>, shown: String) -> some View {
        PanelRow(title: title, value: shown) {
            Slider(value: Binding(
                get: { state.look[keyPath: value] },
                set: { newValue in
                    var look = state.look
                    // Snap to the plain page near zero, so it is easy to turn an effect off.
                    look[keyPath: value] = abs(newValue) < 0.03 ? 0 : (newValue * 100).rounded() / 100
                    state.previewLook = look
                }
            ), in: range) { editing in
                if !editing { state.commitLook() }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        value == 0 ? "Off" : "\(Int((value * 100).rounded()))%"
    }

    private func signedPercent(_ value: Double) -> String {
        value == 0 ? "Off" : String(format: "%+d%%", Int((value * 100).rounded()))
    }
}

// MARK: - More

struct MoreSettingsPanel: View {
    let state: ReaderState
    let onCrop: () -> Void

    var body: some View {
        BarPanel(title: "More", width: 320) {
            VStack(spacing: 0) {
                row(state.crop == nil ? "Crop Pages…" : "Edit Page Crop…", systemImage: "crop", action: onCrop)
                    .accessibilityIdentifier("reader-crop")
                Divider().padding(.leading, 40)
                row("Use as Defaults for All Books", systemImage: "checkmark.circle") { state.useAsDefaults() }
                    .accessibilityIdentifier("reader-use-defaults")
                Divider().padding(.leading, 40)
                row("Reset to Defaults", systemImage: "arrow.uturn.backward") { state.resetToDefaults() }
                    .disabled(!state.hasOwnSettings)
                    .opacity(state.hasOwnSettings ? 1 : 0.4)
                    .accessibilityIdentifier("reader-reset-defaults")
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .tertiarySystemFill)))
            Text(state.hasOwnSettings ? "This book has its own settings." : "This book follows the defaults in Settings › Book Defaults.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("reader-more-panel")
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .foregroundStyle(Color.primary)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A binding to one setting as the reader uses it; setting it makes it this book's own.
@MainActor
private func setting<Value>(_ state: ReaderState, _ current: KeyPath<ReaderState, Value>,
                            _ set: @escaping (inout ReaderOptions, Value) -> Void) -> Binding<Value> {
    Binding(
        get: { state[keyPath: current] },
        set: { value in state.change { set(&$0, value) } }
    )
}
