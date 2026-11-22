import ComicCore
import LibraryKit
import SwiftUI

/// One field of the book data editor (#76), with how to read and write it as text.
enum DataField: String, CaseIterable, Identifiable, Hashable {
    case title, series, number, volume, count
    case writers, pencillers, inkers, colorists, letterers, coverArtists, editors, translators
    case publisher, imprint, year, month, day
    case genres, language, ageRating, summary, isbn, web

    var id: String { rawValue }

    enum Access {
        case text(WritableKeyPath<BookData, String?>)
        case list(WritableKeyPath<BookData, [String]?>)
        case number(WritableKeyPath<BookData, Int?>)
    }

    var access: Access {
        switch self {
        case .title: return .text(\.title)
        case .series: return .text(\.series)
        case .number: return .text(\.number)
        case .volume: return .text(\.volume)
        case .count: return .number(\.count)
        case .writers: return .list(\.writers)
        case .pencillers: return .list(\.pencillers)
        case .inkers: return .list(\.inkers)
        case .colorists: return .list(\.colorists)
        case .letterers: return .list(\.letterers)
        case .coverArtists: return .list(\.coverArtists)
        case .editors: return .list(\.editors)
        case .translators: return .list(\.translators)
        case .publisher: return .text(\.publisher)
        case .imprint: return .text(\.imprint)
        case .year: return .number(\.year)
        case .month: return .number(\.month)
        case .day: return .number(\.day)
        case .genres: return .list(\.genres)
        case .language: return .text(\.language)
        case .ageRating: return .text(\.ageRating)
        case .summary: return .text(\.summary)
        case .isbn: return .text(\.isbn)
        case .web: return .text(\.web)
        }
    }

    var label: String {
        switch self {
        case .title: return "Title"
        case .series: return "Series"
        case .number: return "Number"
        case .volume: return "Volume"
        case .count: return "Books in Series"
        case .writers: return "Writers"
        case .pencillers: return "Pencillers"
        case .inkers: return "Inkers"
        case .colorists: return "Colorists"
        case .letterers: return "Letterers"
        case .coverArtists: return "Cover Artists"
        case .editors: return "Editors"
        case .translators: return "Translators"
        case .publisher: return "Publisher"
        case .imprint: return "Imprint"
        case .year: return "Year"
        case .month: return "Month"
        case .day: return "Day"
        case .genres: return "Genre"
        case .language: return "Language"
        case .ageRating: return "Age Rating"
        case .summary: return "Summary"
        case .isbn: return "ISBN"
        case .web: return "Web Link"
        }
    }

    func text(in data: BookData) -> String {
        switch access {
        case .text(let path): return data[keyPath: path] ?? ""
        case .list(let path): return (data[keyPath: path] ?? []).joined(separator: ", ")
        case .number(let path): return data[keyPath: path].map(String.init) ?? ""
        }
    }

    /// Writes typed text into `data`; empty text clears the field.
    func set(_ text: String, in data: inout BookData) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch access {
        case .text(let path): data[keyPath: path] = trimmed.isEmpty ? nil : trimmed
        case .list(let path): data[keyPath: path] = BookData.names(trimmed)
        case .number(let path): data[keyPath: path] = Int(trimmed).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    var isNumber: Bool { if case .number = access { return true } else { return false } }
    var isList: Bool { if case .list = access { return true } else { return false } }

    /// Values already in the library that the field suggests as you type.
    var suggests: Bool {
        switch self {
        case .series, .writers, .pencillers, .inkers, .colorists, .letterers, .coverArtists, .editors, .translators,
             .publisher, .imprint, .genres, .language, .ageRating: return true
        default: return false
        }
    }

    struct FieldGroup: Identifiable {
        let title: String
        let fields: [DataField]
        var id: String { title }
    }

    /// The editor's sections, in order.
    static let groups: [FieldGroup] = [
        FieldGroup(title: "Book", fields: [.title, .series, .number, .volume, .count]),
        FieldGroup(title: "People", fields: [.writers, .pencillers, .inkers, .colorists, .letterers, .coverArtists, .editors, .translators]),
        FieldGroup(title: "Published", fields: [.publisher, .imprint, .year, .month, .day]),
        FieldGroup(title: "About", fields: [.genres, .language, .ageRating, .summary, .isbn, .web]),
    ]

    /// What Edit Series… sets on every volume.
    static let seriesFields: [DataField] = [.series, .writers, .publisher, .genres]
}

/// Edits book data for one book, many books (Select mode) or a whole series (#76). Each field
/// shows the user's edit; its placeholder is what the file (or the file name) says, or "Mixed"
/// when the books differ. Only the fields you change are written, and the files are never touched.
struct BookDataEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bookIds: Set<String>
    /// Set for Edit Series…, which shows only the fields a whole series shares.
    var seriesName: String?
    /// False when pushed inside another sheet (Book Info), which has its own way back.
    var inSheet = true

    @State private var texts: [DataField: String] = [:]
    @State private var placeholders: [DataField: String] = [:]
    /// Fields whose edit differs between the books; they stay as they are unless typed in.
    @State private var mixed: Set<DataField> = []
    @State private var touched: Set<DataField> = []
    @State private var suggestions: [DataField: [String]] = [:]
    @State private var loaded = false
    @FocusState private var focus: DataField?

    private var books: [Book] { bookIds.compactMap { model.book(id: $0) } }

    private var groups: [DataField.FieldGroup] {
        if seriesName != nil { return [DataField.FieldGroup(title: "Series", fields: DataField.seriesFields)] }
        return DataField.groups
    }

    private var title: String {
        if let seriesName { return "Edit \(seriesName)" }
        return bookIds.count == 1 ? "Edit Info" : "Edit \(bookIds.count) Books"
    }

    var body: some View {
        let content = Form {
            if bookIds.count > 1 {
                Section {
                    Text(seriesName != nil
                         ? "Changes apply to all \(bookIds.count) books in the series."
                         : "Fields marked Mixed differ between the books and stay as they are unless you type in them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.fields) { field in fieldRow(field) }
                } header: {
                    Text(group.title)
                } footer: {
                    if group.title == "People" {
                        Text("Separate names with commas. A book is listed under its writers, or its pencillers if it has no writer.")
                    } else if group.title == "About" {
                        Text("Edits are kept with Comic Reader's data and sync to your other devices. The comic files are not changed.")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
                .disabled(touched.isEmpty)
                .accessibilityIdentifier("data-save")
            }
        }
        .onAppear(perform: load)

        if inSheet {
            NavigationStack { content }
        } else {
            content
        }
    }

    @ViewBuilder private func fieldRow(_ field: DataField) -> some View {
        let binding = Binding(
            get: { texts[field] ?? "" },
            set: { new in
                texts[field] = new
                touched.insert(field)
            }
        )
        let edited = !(texts[field] ?? "").isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: field == .summary ? .top : .firstTextBaseline, spacing: 12) {
                Text(field.label)
                    .frame(width: 130, alignment: .leading)
                    .foregroundStyle(.primary)
                Group {
                    if field == .summary {
                        TextField(field.label, text: binding, prompt: prompt(field), axis: .vertical)
                            .lineLimit(3...8)
                    } else {
                        TextField(field.label, text: binding, prompt: prompt(field))
                            .keyboardType(field.isNumber ? .numberPad : (field == .web ? .URL : .default))
                            .textInputAutocapitalization(field == .web || field == .isbn ? .never : .words)
                            .autocorrectionDisabled(field != .summary)
                    }
                }
                .focused($focus, equals: field)
                .accessibilityIdentifier("data-\(field.rawValue)")
                if edited || (touched.contains(field) && mixed.contains(field)) {
                    // Back to what the file says (#76).
                    Button {
                        texts[field] = ""
                        touched.insert(field)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset \(field.label) to File")
                }
            }
            if focus == field, field.suggests {
                suggestionRow(field)
            }
        }
    }

    private func prompt(_ field: DataField) -> Text {
        if mixed.contains(field), !touched.contains(field) { return Text("Mixed") }
        return Text(placeholders[field] ?? "")
    }

    /// Up to four values from the library that start with (or contain) what is typed, for the
    /// last name in a list.
    @ViewBuilder private func suggestionRow(_ field: DataField) -> some View {
        let typed = texts[field] ?? ""
        let parts = typed.split(separator: ",", omittingEmptySubsequences: false)
        let current = (field.isList ? parts.last.map(String.init) : typed)?.trimmingCharacters(in: .whitespaces) ?? ""
        let matches = matchingSuggestions(field, current, excluding: Set(parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }))
        if !current.isEmpty, !matches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(matches, id: \.self) { value in
                        Button(value) {
                            if field.isList {
                                let kept = parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                texts[field] = (kept + [value]).joined(separator: ", ")
                            } else {
                                texts[field] = value
                            }
                            touched.insert(field)
                        }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.leading, 142)
        }
    }

    private func matchingSuggestions(_ field: DataField, _ typed: String, excluding: Set<String>) -> [String] {
        guard !typed.isEmpty else { return [] }
        let all = suggestions[field] ?? []
        let starts = all.filter { $0.range(of: typed, options: [.caseInsensitive, .anchored, .widthInsensitive]) != nil }
        let contains = all.filter { $0.range(of: typed, options: [.caseInsensitive, .widthInsensitive]) != nil }
        var seen: Set<String> = []
        return (starts + contains).filter { value in
            value.caseInsensitiveCompare(typed) != .orderedSame && !excluding.contains(value.lowercased())
                && seen.insert(value.lowercased()).inserted
        }.prefix(4).map { $0 }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let books = books
        let rules = model.fileNameRules
        let fields = groups.flatMap(\.fields)
        let bases = books.map { $0.baseInfo(rules: rules) }
        for field in fields {
            let edits = Set(books.map { field.text(in: $0.userData ?? BookData()) })
            if edits.count == 1 {
                texts[field] = edits.first ?? ""
            } else {
                texts[field] = ""
                mixed.insert(field)
            }
            let base = Set(bases.map { field.text(in: $0) })
            if base.count == 1 {
                placeholders[field] = base.first ?? ""
            } else {
                // The books' own values differ; the placeholder says so.
                placeholders[field] = "Mixed"
            }
        }
        for field in fields where field.suggests {
            suggestions[field] = model.knownValues { book in
                switch field.access {
                case .text(let path): return book.info[keyPath: path].map { [$0] } ?? []
                case .list(let path): return book.info[keyPath: path] ?? []
                case .number: return []
                }
            }
        }
    }

    private func save() {
        let changes = touched.map { ($0, texts[$0] ?? "") }
        guard !changes.isEmpty else { return }
        model.editBookData(bookIds) { data in
            for (field, text) in changes { field.set(text, in: &data) }
        }
    }
}
