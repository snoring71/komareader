import SwiftUI

/// Past searches for one search field (#109), newest first, kept on this iPad across launches.
/// Each field (books, series, folders) has its own list.
enum SearchHistory {
    static let limit = 50

    static func key(_ list: String) -> String { "searchHistory.\(list)" }

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    static func encode(_ list: [String]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `term` moved (or added) to the top. A repeat that differs only in case or extra spaces
    /// replaces the old one.
    static func adding(_ term: String, to list: [String]) -> [String] {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return list }
        let rest = list.filter { $0.compare(term, options: [.caseInsensitive, .widthInsensitive]) != .orderedSame }
        return Array(([term] + rest).prefix(limit))
    }
}

extension View {
    /// `.searchable` plus a glass box of past searches under the field while search is active
    /// and the field is empty (#109). Tapping one searches for it again; its X removes it.
    func searchableWithHistory(text: Binding<String>, prompt: String, list: String) -> some View {
        modifier(SearchHistoryModifier(text: text, prompt: prompt, list: list))
    }
}

private struct SearchHistoryModifier: ViewModifier {
    @Binding var text: String
    let prompt: String
    let list: String
    @AppStorage private var raw: String

    init(text: Binding<String>, prompt: String, list: String) {
        _text = text
        self.prompt = prompt
        self.list = list
        _raw = AppStorage(wrappedValue: "", SearchHistory.key(list))
    }

    func body(content: Content) -> some View {
        content
            // The keyboard coming and going must not move the grid: starting a search keeps
            // the library exactly where it was.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Inside `.searchable`, so it can read whether search is active.
            .background { SearchWatcher(text: $text, raw: $raw) }
            .searchable(text: $text, prompt: prompt)
            .onSubmit(of: .search) { raw = SearchHistory.encode(SearchHistory.adding(text, to: SearchHistory.decode(raw))) }
    }
}

/// Shows the box while search is active with nothing typed, keeps searches that led somewhere
/// (not only ones ended with Return), and fades the Resume button while the box is up.
private struct SearchWatcher: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var raw: String

    var body: some View {
        let history = SearchHistory.decode(raw)
        let shown = isSearching && text.isEmpty && !history.isEmpty
        Color.clear
            .onChange(of: shown, initial: true) { _, now in
                model.searchHistoryShown = now
                update(history, shown: now)
            }
            .onChange(of: raw) { update(SearchHistory.decode(raw), shown: shown) }
            // Opening a book from the results.
            .onChange(of: model.openBook != nil) { _, opened in
                if opened, isSearching { remember(text) }
            }
            // Opening a series or folder from the results, which pushes a new screen.
            .onDisappear {
                if isSearching { remember(text) }
                model.searchHistoryShown = false
                SearchHistoryPanel.shared.hide()
            }
    }

    private func update(_ history: [String], shown: Bool) {
        let panel = SearchHistoryPanel.shared
        guard shown else { panel.hide(); return }
        panel.show(history,
                   pick: { term in
                       text = term
                       remember(term)
                   },
                   remove: { term in
                       raw = SearchHistory.encode(SearchHistory.decode(raw).filter { $0 != term })
                   })
    }

    private func remember(_ term: String) {
        raw = SearchHistory.encode(SearchHistory.adding(term, to: SearchHistory.decode(raw)))
    }
}

/// The box lives in a window of its own above the app's, not in the library view. With nothing
/// typed, a touch anywhere in the app's window outside the search field ends the search, and a
/// box drawn there closed (or flickered the keyboard and moved the grid) whenever it was
/// scrolled or a row was deleted. Touches in this window never reach the app's, the window never
/// becomes key, so the search field keeps the keyboard.
@MainActor @Observable
final class SearchHistoryPanel {
    static let shared = SearchHistoryPanel()

    fileprivate(set) var terms: [String] = []
    fileprivate(set) var isShown = false
    fileprivate var pick: (String) -> Void = { _ in }
    fileprivate var remove: (String) -> Void = { _ in }
    /// The top of the on-screen keyboard in window points, or nil when there is none.
    fileprivate var keyboardTop: CGFloat?
    /// Where the box is, in window points; touches elsewhere pass through to the app.
    @ObservationIgnored fileprivate var boxFrame: CGRect = .zero
    @ObservationIgnored private var window: PanelWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func show(_ terms: [String], pick: @escaping (String) -> Void, remove: @escaping (String) -> Void) {
        self.pick = pick
        self.remove = remove
        installWindow()
        withAnimation(.snappy(duration: 0.2)) {
            self.terms = terms
            isShown = !terms.isEmpty
        }
    }

    func hide() {
        guard isShown else { return }
        withAnimation(.snappy(duration: 0.2)) { isShown = false }
    }

    private func installWindow() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let window = PanelWindow(windowScene: scene)
        window.panel = self
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: SearchHistoryBox(panel: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                // A hardware keyboard leaves only a small bar, or nothing, on screen.
                self.keyboardTop = end.minY < window.bounds.height - 1 ? end.minY : nil
            }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardTop = nil }
        })
    }

    fileprivate final class PanelWindow: UIWindow {
        weak var panel: SearchHistoryPanel?

        override var canBecomeKey: Bool { false }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let panel, panel.isShown, panel.boxFrame.contains(point) else { return nil }
            return super.hitTest(point, with: event)
        }
    }
}

private struct SearchHistoryBox: View {
    let panel: SearchHistoryPanel

    /// Below the search field in the toolbar: the status bar plus the toolbar row.
    private static let belowToolbar: CGFloat = 54
    /// Space kept between the box and the top of the keyboard.
    private static let keyboardGap: CGFloat = 24
    private static let rowHeight: CGFloat = 45

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.safeAreaInsets.top + Self.belowToolbar
            let height = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let bottom = min(height, panel.keyboardTop ?? .infinity) - Self.keyboardGap
            ZStack(alignment: .topTrailing) {
                if panel.isShown {
                    box(maxHeight: max(Self.rowHeight * 2, bottom - top))
                        .padding(.top, top)
                        .padding(.trailing, 16 + proxy.safeAreaInsets.trailing)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
    }

    private func box(maxHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(panel.terms.enumerated()), id: \.element) { index, term in
                    if index > 0 { Divider().padding(.leading, 44) }
                    row(term)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.basedOnSize)
        // Up to about eight rows; more scroll.
        .frame(height: min(CGFloat(panel.terms.count) * Self.rowHeight + 12, 372, maxHeight))
        .frame(width: 340)
        .clipShape(shape)
        .background { Color.clear.glassEffect(in: shape) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { panel.boxFrame = $0 }
        .accessibilityIdentifier("search-history")
    }

    private func row(_ term: String) -> some View {
        HStack(spacing: 12) {
            Button {
                panel.pick(term)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(term)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("search-history-term-\(term)")

            Button {
                panel.remove(term)
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Remove “\(term)” from search history")
            .accessibilityIdentifier("search-history-remove-\(term)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 44)
    }
}
