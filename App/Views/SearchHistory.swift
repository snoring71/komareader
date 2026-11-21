import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
    @State private var presented = false
    @FocusState private var focused: Bool

    init(text: Binding<String>, prompt: String, list: String) {
        _text = text
        self.prompt = prompt
        self.list = list
        _raw = AppStorage(wrappedValue: "", SearchHistory.key(list))
    }

    func body(content: Content) -> some View {
        content
            // Inside `.searchable`, so the box can read whether search is active.
            .overlay(alignment: .topTrailing) {
                SearchHistoryBox(text: $text, raw: $raw, list: list) {
                    presented = true
                    focused = true
                }
            }
            .searchable(text: $text, isPresented: $presented, prompt: prompt)
            .searchFocused($focused)
            .onSubmit(of: .search) { remember() }
    }

    private func remember() {
        raw = SearchHistory.encode(SearchHistory.adding(text, to: SearchHistory.decode(raw)))
    }
}

private struct SearchHistoryBox: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var raw: String
    let list: String
    /// Starts the search again, keyboard up, after a touch in the box ended it.
    let reopen: () -> Void
    /// Kept open after the search ended because the touch that ended it was in the box.
    @State private var held = false
    @State private var boxFrame: CGRect = .zero
    /// The top of the keyboard in screen points, or nil when no on-screen keyboard is up.
    @State private var keyboardTop: CGFloat?

    /// Below the search field in the toolbar: the status bar plus the toolbar row.
    private static let belowToolbar: CGFloat = 54
    /// Space kept between the box and the top of the keyboard.
    private static let keyboardGap: CGFloat = 24
    private static let rowHeight: CGFloat = 45

    var body: some View {
        let history = SearchHistory.decode(raw)
        let shown = (isSearching || held) && text.isEmpty && !history.isEmpty
        // Laid out over the whole screen and placed by screen position, not by the grid's safe
        // area: that area grows with the large title, which left a gap above the box when
        // search started at the very top of the library.
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let top = Self.windowTopInset + Self.belowToolbar - frame.minY
            let bottom = min(frame.height, (keyboardTop ?? .infinity) - frame.minY) - Self.keyboardGap
            ZStack(alignment: .topTrailing) {
                if shown {
                    box(history, maxHeight: max(Self.rowHeight * 2, bottom - top))
                        .padding(.top, top)
                        .padding(.trailing, 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.2), value: shown)
        .onChange(of: shown, initial: true) { _, now in model.searchHistoryShown = now }
        .onAppear { TouchTracker.install() }
        // Touching anywhere outside the search field ends a search with nothing typed, and
        // that includes the box: scrolling it or deleting a row closed it. When the touch that
        // ended the search was in the box, keep the box and start the search again.
        .onChange(of: isSearching) { _, searching in
            if searching {
                held = false
            } else if TouchTracker.touchedRecently(in: boxFrame) {
                held = true
                reopen()
            } else {
                held = false
            }
        }
        .onChange(of: text) { _, new in if !new.isEmpty { held = false } }
        .onReceive(NotificationCenter.default.publisher(for: TouchTracker.touchDown)) { note in
            // A touch elsewhere lets a held box go.
            if held, let point = note.object as? CGPoint, !boxFrame.contains(point) { held = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = Self.screenHeight
            // A hardware keyboard leaves only a small bar, or nothing, on screen.
            keyboardTop = end.minY < screen - 1 ? end.minY : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardTop = nil
        }
        // Searches that led somewhere are kept too, not only ones ended with Return: opening a
        // book from the results, or a series or folder (which pushes a new screen).
        .onChange(of: model.openBook != nil) { _, opened in
            if opened, isSearching { remember() }
        }
        .onDisappear {
            if isSearching { remember() }
            model.searchHistoryShown = false
        }
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    private static var windowTopInset: CGFloat { keyWindow?.safeAreaInsets.top ?? 24 }
    private static var screenHeight: CGFloat { keyWindow?.screen.bounds.height ?? .infinity }

    private func box(_ history: [String], maxHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.element) { index, term in
                    if index > 0 { Divider().padding(.leading, 44) }
                    row(term)
                }
            }
            .padding(.vertical, 6)
        }
        // Scrolling the list must not put the keyboard away: with the field empty, that ends
        // the search and closes the box mid-scroll.
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.basedOnSize)
        // Up to about eight rows; more scroll.
        .frame(height: min(CGFloat(history.count) * Self.rowHeight + 12, 372, maxHeight))
        .frame(width: 340)
        .clipShape(shape)
        // The glass sits behind the list rather than on it, so the list keeps its own touches.
        .background { Color.clear.glassEffect(in: shape) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { boxFrame = $0 }
        .accessibilityIdentifier("search-history-\(list)")
    }

    private func row(_ term: String) -> some View {
        HStack(spacing: 12) {
            Button {
                text = term
                remember(term)
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
                withAnimation(.snappy(duration: 0.2)) {
                    raw = SearchHistory.encode(SearchHistory.decode(raw).filter { $0 != term })
                }
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

    private func remember(_ term: String? = nil) {
        raw = SearchHistory.encode(SearchHistory.adding(term ?? text, to: SearchHistory.decode(raw)))
    }
}

/// Notes where and when each touch on the screen starts, without taking part in any gesture,
/// so the search history box can tell whether a touch in it is what ended the search.
@MainActor
enum TouchTracker {
    static let touchDown = Notification.Name("TouchTracker.touchDown")
    private static var last: (point: CGPoint, time: Date)?
    private static var installed = Set<ObjectIdentifier>()

    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !installed.contains(ObjectIdentifier(window)) {
                installed.insert(ObjectIdentifier(window))
                let recognizer = Recognizer(target: nil, action: nil)
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = recognizer
                window.addGestureRecognizer(recognizer)
            }
        }
    }

    static func touchedRecently(in frame: CGRect) -> Bool {
        guard let last, Date().timeIntervalSince(last.time) < 1.5 else { return false }
        return frame.insetBy(dx: -4, dy: -4).contains(last.point)
    }

    fileprivate static func note(_ point: CGPoint) {
        last = (point, Date())
        NotificationCenter.default.post(name: touchDown, object: point)
    }

    private final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first, let window = view {
                TouchTracker.note(touch.location(in: window))
            }
            // Never recognizes, so it never gets in another gesture's way.
            state = .failed
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
    }
}
