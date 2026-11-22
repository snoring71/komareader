import ComicCore
import LibraryKit
import SwiftUI

/// Makes or changes a smart list (#82): a name, Match All or Any, rules (field, comparison,
/// value), and an optional sort and limit. Date rules count days back from today, so "added
/// in the last 30 days" keeps moving.
struct SmartListEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil for a new list.
    let listId: String?
    let initial: LibraryFilter

    @State private var name = ""
    @State private var filter = LibraryFilter()
    /// Nil follows the sort chosen in the list's own menu.
    @State private var sort: LibraryGridView.SortOrder?
    @State private var ascending = true
    @State private var limit = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Unread sci-fi added this year"))
                        .accessibilityIdentifier("smart-name")
                }
                Section {
                    Picker("Match", selection: $filter.match) {
                        Text("All Rules").tag(LibraryFilter.Match.all)
                        Text("Any Rule").tag(LibraryFilter.Match.any)
                    }
                    ForEach($filter.rules) { $rule in
                        RuleRow(rule: $rule) { filter.rules.removeAll { $0.id == rule.id } }
                    }
                    Button("Add Rule", systemImage: "plus") {
                        filter.rules.append(.init(.status, .isAnyOf, ["unread"]))
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("smart-add-rule")
                    TextField("Words", text: Binding(get: { filter.text ?? "" }, set: { filter.text = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Words in titles, series, authors (optional)"))
                } header: {
                    Text("Rules")
                } footer: {
                    Text("Lists of values are separated with commas. Status values are unread, reading and read.")
                }
                Section("Order") {
                    Picker("Sort By", selection: $sort) {
                        Text("As in the List’s Menu").tag(LibraryGridView.SortOrder?.none)
                        ForEach(LibraryGridView.SortOrder.forBooks) { Text($0.rawValue).tag(Optional($0)) }
                    }
                    if sort != nil {
                        Picker("Order", selection: $ascending) {
                            Text("Ascending").tag(true)
                            Text("Descending").tag(false)
                        }
                    }
                    LabeledContent("Show Only the First") {
                        TextField("All", text: $limit)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
                if listId != nil {
                    Section {
                        Button("Delete List", role: .destructive) {
                            if let listId { model.deleteList(listId) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(listId == nil ? "New Smart List" : "Edit Smart List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveSmartList(id: listId, name: name, filter: cleaned, sort: sort?.rawValue,
                                            ascending: sort == nil ? nil : ascending, limit: Int(limit).flatMap { $0 > 0 ? $0 : nil })
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("smart-save")
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Rules with their values trimmed, and rules that need a value but have none left out.
    private var cleaned: LibraryFilter {
        var result = filter
        result.rules = filter.rules.compactMap { rule in
            var rule = rule
            rule.values = rule.values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return rule.op.valueCount != 0 && rule.values.isEmpty ? nil : rule
        }
        return result
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        filter = initial
        if let listId, let list = model.lists.list(listId) {
            name = list.name
            filter = list.filter ?? initial
            sort = list.sort.flatMap(LibraryGridView.SortOrder.init(rawValue:))
            ascending = list.ascending ?? sort?.ascendingByDefault ?? true
            limit = list.limit.map(String.init) ?? ""
        }
    }
}

/// One rule: field, comparison and its value(s).
private struct RuleRow: View {
    @Binding var rule: LibraryFilter.Rule
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Field", selection: Binding(
                    get: { rule.field },
                    set: { field in
                        rule.field = field
                        if !field.operators.contains(rule.op) { rule.op = field.operators[0] }
                        rule.values = Self.starter(field, rule.op)
                    })) {
                    ForEach(LibraryFilter.Field.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Picker("Comparison", selection: $rule.op) {
                    ForEach(rule.field.operators, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Rule")
            }
            .tint(.primary)
            switch rule.op.valueCount {
            case 0:
                EmptyView()
            case 2:
                HStack {
                    TextField("From", text: value(0)).keyboardType(.numberPad)
                    Text("and")
                    TextField("To", text: value(1)).keyboardType(.numberPad)
                }
            case -1:
                TextField("Values", text: Binding(
                    get: { rule.values.joined(separator: ", ") },
                    set: { rule.values = $0.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }))
                    .textInputAutocapitalization(.never)
            default:
                HStack {
                    TextField(rule.field.kind == .date ? "Days" : "Value", text: value(0))
                        .keyboardType(rule.field.kind == .number || rule.field.kind == .date ? .numberPad : .default)
                    if rule.field.kind == .date { Text("days").foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func value(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < rule.values.count ? rule.values[i] : "" },
            set: { new in
                while rule.values.count <= i { rule.values.append("") }
                rule.values[i] = new
            })
    }

    /// A sensible first value for a field just picked.
    static func starter(_ field: LibraryFilter.Field, _ op: LibraryFilter.Op) -> [String] {
        switch field {
        case .status: return ["unread"]
        case .rating: return ["4"]
        case .added, .lastRead, .finished: return ["30"]
        default: return []
        }
    }
}
