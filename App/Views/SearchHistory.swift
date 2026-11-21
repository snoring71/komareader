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
            // Inside `.searchable`, so the box can read whether search is active.
            .overlay(alignment: .topTrailing) {
                SearchHistoryBox(text: $text, raw: $raw, list: list)
            }
            .searchable(text: $text, prompt: prompt)
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

    var body: some View {
        let history = SearchHistory.decode(raw)
        ZStack {
            if isSearching && text.isEmpty && !history.isEmpty {
                box(history)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.2), value: isSearching && text.isEmpty)
        // Searches that led somewhere are kept too, not only ones ended with Return: opening a
        // book from the results, or a series or folder (which pushes a new screen).
        .onChange(of: model.openBook != nil) { _, opened in
            if opened, isSearching { remember() }
        }
        .onDisappear { if isSearching { remember() } }
    }

    private func box(_ history: [String]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.element) { index, term in
                    if index > 0 { Divider().padding(.leading, 44) }
                    row(term)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        // About eight rows show; more scroll.
        .frame(maxHeight: min(CGFloat(history.count) * 45 + 12, 372))
        .frame(width: 340)
        .glassEffect(in: .rect(cornerRadius: 20))
        .padding(.top, 8)
        .padding(.trailing, 16)
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
