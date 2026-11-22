import ComicCore
import LibraryKit
import SwiftUI

extension LibraryFilter {
    /// The filter bar keeps one rule per field.
    func rule(for field: Field) -> Rule? { rules.first { $0.field == field } }

    /// Sets the field's rule, or removes it when `values` is empty for a comparison that needs some.
    mutating func set(_ field: Field, _ op: Op, _ values: [String] = []) {
        let needsValues = op.valueCount != 0
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = rules.firstIndex(where: { $0.field == field }) {
            if needsValues && cleaned.isEmpty { rules.remove(at: i) } else { rules[i].op = op; rules[i].values = cleaned }
        } else if !needsValues || !cleaned.isEmpty {
            rules.append(Rule(field, op, cleaned))
        }
    }

    mutating func remove(_ field: Field) { rules.removeAll { $0.field == field } }

    /// Both filters together: every rule of each, and both sets of plain words.
    func combined(with other: LibraryFilter) -> LibraryFilter {
        if other.isEmpty { return self }
        if isEmpty { return other }
        // Rules from a filter that matches any of them cannot be merged into a list of rules
        // that must all hold; such a filter stays as it is.
        guard match == .all, other.match == .all else { return self }
        let words = [text, other.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return LibraryFilter(match: .all, rules: rules + other.rules, text: words.isEmpty ? nil : words)
    }
}

extension LibraryFilter.Rule {
    /// The chip's words: "Unread, Read", "Favorite", "★ 4+", "Year 2010–2015", "Author: 天野".
    var summary: String {
        let list = values.joined(separator: ", ")
        switch field {
        case .status:
            let names = values.map { $0.capitalized }.joined(separator: ", ")
            return op == .isNoneOf ? "Not \(names)" : names
        case .favorite: return op == .isTrue ? "Favorite" : "Not Favorite"
        case .bookmarked: return op == .isTrue ? "Bookmarked" : "Not Bookmarked"
        case .downloaded: return op == .isTrue ? "Downloaded" : "In iCloud"
        case .rating:
            if op == .atMost, values.first == "0" { return "Not Rated" }
            if op == .atLeast, let n = values.first { return "★ \(n)+" }
        case .format:
            let names = values.map { BookFormat(rawValue: $0)?.displayName ?? $0.uppercased() }.joined(separator: ", ")
            return op == .isNoneOf ? "Not \(names)" : names
        case .tag where op == .isAnyOf && values.count == 1: return "Tag: \(list)"
        default: break
        }
        switch op {
        case .between where values.count == 2: return "\(field.title) \(values[0])–\(values[1])"
        case .inLast, .notInLast: return "\(field.title) \(op.title) \(values.first ?? "30") days"
        case .isSet, .isNotSet, .isTrue, .isFalse: return "\(field.title) \(op.title)"
        case .contains: return "\(field.title): \(list)"
        default: return "\(field.title) \(op.title) \(list)"
        }
    }
}

/// The active filters as chips under the toolbar (#80), each with a remove button, then Clear
/// All and Save as Smart List….
struct FilterChips: View {
    @Binding var filter: LibraryFilter
    /// Rules typed in the search field, shown as chips too but removed by editing the search.
    var typed: LibraryFilter
    var onSave: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filter.rules) { rule in
                    HStack(spacing: 4) {
                        Text(rule.summary).lineLimit(1)
                        Button {
                            filter.rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(rule.summary)")
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("filter-chip-\(rule.field.rawValue)")
                }
                ForEach(typed.rules) { rule in
                    Text(rule.summary)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Color.primary.opacity(0.25)))
                }
                if !filter.rules.isEmpty {
                    Button("Clear All") { filter = LibraryFilter() }
                        .font(.footnote)
                        .tint(.primary)
                        .accessibilityIdentifier("filter-clear")
                }
                Button("Save as Smart List…", systemImage: "plus.circle", action: onSave)
                    .font(.footnote)
                    .tint(.primary)
                    .accessibilityIdentifier("filter-save-smart")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .foregroundStyle(Color.primary)
    }
}

/// The Filter button's panel (#80): status, on this iPad, Favorite, Bookmarked, rating, format,
/// tags, author, publisher and year. Every choice is a rule of the same filter smart lists save.
struct FilterPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: LibraryFilter
    @State private var yearFrom = ""
    @State private var yearTo = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    ForEach(Book.Status.allValues, id: \.self) { status in
                        Toggle(status.rawValue.capitalized, isOn: chosen(.status, status.rawValue))
                    }
                }
                Section {
                    Picker("On This iPad", selection: Binding(
                        get: { filter.rule(for: .downloaded).map { $0.op == .isTrue ? 1 : 2 } ?? 0 },
                        set: { value in
                            if value == 0 { filter.remove(.downloaded) } else { filter.set(.downloaded, value == 1 ? .isTrue : .isFalse) }
                        })) {
                        Text("Any").tag(0)
                        Text("Downloaded").tag(1)
                        Text("In iCloud Only").tag(2)
                    }
                    Toggle("Favorites Only", isOn: flag(.favorite))
                    Toggle("Bookmarked Only", isOn: flag(.bookmarked))
                    Picker("Rating", selection: Binding(
                        get: { filter.rule(for: .rating).flatMap { $0.op == .atLeast ? $0.values.first.flatMap(Int.init) : -1 } ?? 0 },
                        set: { value in
                            switch value {
                            case 0: filter.remove(.rating)
                            case -1: filter.set(.rating, .atMost, ["0"])
                            default: filter.set(.rating, .atLeast, [String(value)])
                            }
                        })) {
                        Text("Any").tag(0)
                        ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0) + ($0 < 5 ? " or more" : "")).tag($0) }
                        Text("Not Rated").tag(-1)
                    }
                }
                let formats = Set(model.books.map(\.format))
                if formats.count > 1 {
                    Section("Format") {
                        ForEach(BookFormat.allCases.filter(formats.contains), id: \.self) { format in
                            Toggle(format.displayName, isOn: chosen(.format, format.rawValue))
                        }
                    }
                }
                if !model.summary.tags.isEmpty {
                    Section {
                        Picker("Match", selection: Binding(
                            get: { filter.rule(for: .tag)?.op ?? .isAnyOf },
                            set: { op in
                                if let rule = filter.rule(for: .tag) { filter.set(.tag, op, rule.values) }
                            })) {
                            Text("Any of These").tag(LibraryFilter.Op.isAnyOf)
                            Text("All of These").tag(LibraryFilter.Op.isAllOf)
                        }
                        ForEach(model.summary.tags) { tag in
                            Toggle(tag.name, isOn: chosen(.tag, tag.name, op: filter.rule(for: .tag)?.op ?? .isAnyOf))
                        }
                    } header: {
                        Text("Tags")
                    }
                }
                Section {
                    namePicker("Author", field: .author, names: model.catalog.authors.map(\.name).filter { !$0.isEmpty })
                    namePicker("Publisher", field: .publisher, names: model.catalog.publishers.map(\.name).filter { !$0.isEmpty })
                    HStack {
                        Text("Release Year")
                        Spacer()
                        TextField("From", text: $yearFrom).keyboardType(.numberPad).frame(width: 64).multilineTextAlignment(.trailing)
                        Text("–")
                        TextField("To", text: $yearTo).keyboardType(.numberPad).frame(width: 64)
                    }
                    .onChange(of: yearFrom) { applyYears() }
                    .onChange(of: yearTo) { applyYears() }
                }
                if !filter.rules.isEmpty {
                    Section {
                        Button("Clear All Filters", role: .destructive) { filter = LibraryFilter() }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let year = filter.rule(for: .year) {
                    yearFrom = year.values.first ?? ""
                    yearTo = year.values.count > 1 ? year.values[1] : ""
                }
            }
        }
        .toggleStyle(MonoToggleStyle())
        .frame(minWidth: 360, minHeight: 520)
    }

    /// A toggle for one value of a rule that holds several (status, format, tags).
    private func chosen(_ field: LibraryFilter.Field, _ value: String, op: LibraryFilter.Op = .isAnyOf) -> Binding<Bool> {
        Binding(
            get: { filter.rule(for: field)?.values.contains { $0.caseInsensitiveCompare(value) == .orderedSame } ?? false },
            set: { on in
                var values = filter.rule(for: field)?.values ?? []
                values.removeAll { $0.caseInsensitiveCompare(value) == .orderedSame }
                if on { values.append(value) }
                filter.set(field, op, values)
            })
    }

    private func flag(_ field: LibraryFilter.Field) -> Binding<Bool> {
        Binding(
            get: { filter.rule(for: field)?.op == .isTrue },
            set: { on in if on { filter.set(field, .isTrue) } else { filter.remove(field) } })
    }

    private func namePicker(_ title: String, field: LibraryFilter.Field, names: [String]) -> some View {
        Picker(title, selection: Binding(
            get: { filter.rule(for: field)?.values.first ?? "" },
            set: { name in
                if name.isEmpty { filter.remove(field) } else { filter.set(field, .is, [name]) }
            })) {
            Text("Any").tag("")
            ForEach(names, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private func applyYears() {
        let from = Int(yearFrom), to = Int(yearTo)
        switch (from, to) {
        case let (a?, b?): filter.set(.year, .between, [String(min(a, b)), String(max(a, b))])
        case let (a?, nil): filter.set(.year, .atLeast, [String(a)])
        case let (nil, b?): filter.set(.year, .atMost, [String(b)])
        default: filter.remove(.year)
        }
    }
}

extension Book.Status {
    static let allValues: [Book.Status] = [.unread, .reading, .read]
}

/// Suggestions under the search field as a prefix is typed (#81): the prefixes themselves,
/// then matching authors, publishers, series, tags and genres, so nobody has to remember them.
struct SearchFieldSuggestions: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String

    var body: some View {
        let tokens = LibraryFilter.tokens(search)
        let endsWithSpace = search.last?.isWhitespace ?? true
        let last = endsWithSpace ? "" : (tokens.last ?? "")
        let before = endsWithSpace ? search : String(search.dropLast(last.count))
        if let colon = last.firstIndex(of: ":") {
            let key = last[..<colon].lowercased()
            let typed = last[last.index(after: colon)...].replacingOccurrences(of: "\"", with: "")
            ForEach(values(for: key, matching: typed), id: \.self) { value in
                let quoted = value.contains(" ") ? "\"\(value)\"" : value
                Label(value, systemImage: icon(for: key))
                    .searchCompletion(before + key + ":" + quoted + " ")
            }
        } else if !last.isEmpty {
            ForEach(LibraryFilter.prefixes.filter { $0.hasPrefix(last.lowercased()) && $0 != last.lowercased() }, id: \.self) { prefix in
                Label(prefix, systemImage: "text.magnifyingglass")
                    .searchCompletion(before + prefix)
            }
        }
    }

    private func icon(for key: String) -> String {
        switch key {
        case "author": return "person"
        case "publisher": return "building.columns"
        case "series": return "square.stack"
        case "tag": return "tag"
        default: return "magnifyingglass"
        }
    }

    /// Up to eight known values for a prefix, starting with the typed text first.
    private func values(for key: String, matching typed: String) -> [String] {
        let all: [String]
        switch key {
        case "author", "writer", "by": all = model.catalog.authors.map(\.name).filter { !$0.isEmpty }
        case "publisher": all = model.catalog.publishers.map(\.name).filter { !$0.isEmpty }
        case "series": all = model.catalog.series.map(\.name)
        case "tag": all = model.summary.tags.map(\.name)
        case "genre": all = model.knownValues { $0.info.genres ?? [] }
        case "format": all = Array(Set(model.books.map { $0.format.displayName.lowercased() })).sorted()
        case "status": all = ["unread", "reading", "read"]
        case "is": all = ["favorite", "bookmarked", "downloaded", "cloud", "rated", "unread", "reading", "read"]
        case "rating": all = [">=5", ">=4", ">=3", ">=2", ">=1"]
        default: all = []
        }
        guard !typed.isEmpty else { return Array(all.prefix(8)) }
        let folded = SearchKey.fold(typed)
        let starts = all.filter { SearchKey.fold($0).hasPrefix(folded) }
        let contains = all.filter { !SearchKey.fold($0).hasPrefix(folded) && SearchKey.fold($0).contains(folded) }
        return Array((starts + contains).prefix(8))
    }
}
