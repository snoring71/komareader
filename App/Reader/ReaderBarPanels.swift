import ArchiveKit
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
        .accessibilityElement(children: .contain)
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
        .accessibilityElement(children: .contain)
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
                        .stroke(Color.primary, lineWidth: 2.5)
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
        .accessibilityElement(children: .contain)
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
    /// Use as Defaults was tapped once and is waiting to be confirmed.
    @State private var confirmingDefaults = false
    /// Two pages are on screen: Share Page asks which one.
    @State private var choosingPage = false
    /// The page file is being made (an archive page still unpacking, a PDF page rendering).
    @State private var preparingShare = false
    @State private var shareFailed = false
    @State private var shareAnchor = ShareAnchor.Holder()

    var body: some View {
        BarPanel(title: "More", width: 320) {
            VStack(spacing: 0) {
                if choosingPage {
                    choosePage
                        .transition(.opacity)
                } else {
                    row(shareFailed ? "Couldn’t Share This Page" : "Share Page", systemImage: "square.and.arrow.up") { sharePage() }
                        .overlay(alignment: .trailing) {
                            if preparingShare { ProgressView().padding(.trailing, 12) }
                        }
                        .disabled(preparingShare)
                        .accessibilityIdentifier("reader-share-page")
                        .transition(.opacity)
                }
                Divider().padding(.leading, 40)
                if confirmingDefaults {
                    confirmDefaults
                        .transition(.opacity)
                } else {
                    row("Use as Defaults for All Books", systemImage: "checkmark.circle") { confirmingDefaults = true }
                        .accessibilityIdentifier("reader-use-defaults")
                        .transition(.opacity)
                }
                Divider().padding(.leading, 40)
                row("Reset to Defaults", systemImage: "arrow.uturn.backward") { state.resetToDefaults() }
                    .disabled(!state.hasOwnSettings)
                    .opacity(state.hasOwnSettings ? 1 : 0.4)
                    .accessibilityIdentifier("reader-reset-defaults")
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PanelFill.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PanelFill.edge))
            Text(state.hasOwnSettings ? "This book has its own settings." : "This book follows the defaults in Settings › Book Defaults.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .animation(.easeInOut(duration: 0.2), value: confirmingDefaults)
        .animation(.easeInOut(duration: 0.2), value: choosingPage)
        // The share sheet points at the panel.
        .background(ShareAnchor(holder: shareAnchor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-more-panel")
    }

    /// Shares the page on screen as it is in the book (no crop, split or adjustments). With
    /// two pages showing, asks which one first.
    private func sharePage() {
        let pages = state.pagesOnScreenLeftToRight
        if pages.count > 1 {
            choosingPage = true
        } else if let page = pages.first {
            share(page)
        }
    }

    private var choosePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share which page?")
                .font(.subheadline)
            HStack {
                let pages = state.pagesOnScreenLeftToRight
                Button("Left Page") {
                    choosingPage = false
                    if let left = pages.first { share(left) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reader-share-left")
                Button("Right Page") {
                    choosingPage = false
                    if let right = pages.last { share(right) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("reader-share-right")
                Spacer()
                Button("Cancel") { choosingPage = false }
                    .buttonStyle(.borderless)
            }
            .tint(.primary)
        }
        .padding(12)
    }

    private func share(_ page: Int) {
        preparingShare = true
        shareFailed = false
        let source = state.source, title = state.book.title
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Shared Pages", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task { @MainActor in
            defer { preparingShare = false }
            do {
                let file = try await PageExport.export(source, page: page, title: title, to: directory)
                shareAnchor.present([file]) {
                    try? FileManager.default.removeItem(at: directory)
                }
            } catch {
                shareFailed = true
            }
        }
    }

    /// Asks before changing every book in the library.
    private var confirmDefaults: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use this book's settings for every book that hasn't set its own?")
                .font(.subheadline)
            HStack {
                Button("Cancel") { confirmingDefaults = false }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reader-use-defaults-cancel")
                Spacer()
                Button {
                    state.useAsDefaults()
                    confirmingDefaults = false
                } label: {
                    // Inverse text on the black/white accent fill, so it reads in dark mode too.
                    Text("Use as Defaults").foregroundStyle(Color.onAccent)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("reader-use-defaults-confirm")
            }
        }
        .padding(12)
    }

    private func row(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(Color.primary)
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

/// The reader's bookmarked pages: tap one to go there.
struct BookmarksPanel: View {
    let state: ReaderState
    let close: () -> Void

    var body: some View {
        BarPanel(title: "Bookmarks", width: 320) {
            if state.bookmarks.isEmpty {
                Text("No bookmarked pages yet. Tap the bookmark button to bookmark the page you’re on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.bookmarks.enumerated()), id: \.element) { index, page in
                            if index > 0 { Divider().padding(.leading, 64) }
                            BookmarkRow(state: state, page: page) {
                                state.jump(toPage: page)
                                close()
                            }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .scrollBounceBehavior(.basedOnSize)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(PanelFill.color))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PanelFill.edge))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-bookmarks-panel")
    }
}

private struct BookmarkRow: View {
    let state: ReaderState
    let page: Int
    let open: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Group {
                        if let thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFit()
                        } else {
                            Color.primary.opacity(0.08)
                        }
                    }
                    .frame(width: 36, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Text("Page \(page + 1)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.primary)
                    if state.currentPages.contains(page) {
                        Text("Showing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page \(page + 1)")
            .accessibilityIdentifier("reader-bookmark-\(page + 1)")
            Button {
                state.removeBookmark(page)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove Bookmark on Page \(page + 1)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: page) { thumbnail = await state.thumbnail(for: page) }
    }
}

/// An invisible view in a panel that the share sheet is shown from, so on iPad it points at
/// the panel rather than the middle of the screen.
struct ShareAnchor: UIViewRepresentable {
    @MainActor
    final class Holder {
        weak var view: UIView?

        func present(_ items: [Any], completion: @escaping () -> Void) {
            guard let view, var top = view.owningViewController ?? view.window?.rootViewController else { return }
            while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = view
            sheet.popoverPresentationController?.sourceRect = view.bounds
            sheet.completionWithItemsHandler = { _, _, _, _ in completion() }
            top.present(sheet, animated: true)
        }
    }

    let holder: Holder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        holder.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        holder.view = view
    }
}

private extension UIView {
    /// The view controller whose view holds this one.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// The fill behind grouped controls in the panels, visible on the glass in light and dark.
enum PanelFill {
    static let color = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07)
    })
    static let edge = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.05)
    })
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
