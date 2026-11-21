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
    /// `.searchable` with past searches listed under the field while search is active and the
    /// field is empty (#109). Tapping one searches for it again; its X removes it.
    ///
    /// The list is the system's search suggestions, not a box of our own over the grid: with
    /// nothing typed, any touch outside the search field ends the search, so a box of our own
    /// closed (or flickered the keyboard and moved the grid) whenever it was scrolled or a row
    /// was deleted. Suggestions belong to the search field, so touching them keeps it active.
    func searchableWithHistory(text: Binding<String>, prompt: String, list: String) -> some View {
        modifier(SearchHistoryModifier(text: text, prompt: prompt, list: list))
    }
}

private struct SearchHistoryModifier: ViewModifier {
    @Environment(AppModel.self) private var model
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
        let history = SearchHistory.decode(raw)
        content
            // The keyboard coming and going must not move the grid: starting a search keeps
            // the library exactly where it was.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Inside `.searchable`, so it can read whether search is active.
            .background { SearchWatcher(text: text, hasHistory: !history.isEmpty, remember: remember) }
            .searchable(text: $text, prompt: prompt)
            .searchSuggestions {
                if text.isEmpty {
                    ForEach(history, id: \.self) { term in
                        row(term)
                    }
                }
            }
            .onSubmit(of: .search) { remember() }
    }

    private func row(_ term: String) -> some View {
        HStack(spacing: 12) {
            Label {
                Text(term).lineLimit(1)
            } icon: {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .searchCompletion(term)
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
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove “\(term)” from search history")
            .accessibilityIdentifier("search-history-remove-\(term)")
        }
    }

    private func remember() {
        raw = SearchHistory.encode(SearchHistory.adding(text, to: SearchHistory.decode(raw)))
    }
}

/// Keeps searches that led somewhere, not only ones ended with Return, and fades the Resume
/// button while the history is showing so it doesn't sit on top of it.
private struct SearchWatcher: View {
    @Environment(\.isSearching) private var isSearching
    @Environment(AppModel.self) private var model
    let text: String
    let hasHistory: Bool
    let remember: () -> Void

    var body: some View {
        let shown = isSearching && text.isEmpty && hasHistory
        Color.clear
            .onChange(of: shown, initial: true) { _, now in model.searchHistoryShown = now }
            // Opening a book from the results.
            .onChange(of: model.openBook != nil) { _, opened in
                if opened, isSearching { remember() }
            }
            // Opening a series or folder from the results, which pushes a new screen.
            .onDisappear {
                if isSearching { remember() }
                model.searchHistoryShown = false
            }
    }
}
