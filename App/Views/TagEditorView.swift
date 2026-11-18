import LibraryKit
import SwiftUI

/// A checklist of the library's tags for one book or several (Select mode, #64), with a field
/// for a new tag and a No Tags row. Shown as a sheet from the library's long-press menu or
/// Select mode, or pushed from Book Info (`inSheet: false`). Every tap applies at once, as one
/// batched change across all the books.
struct TagEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bookIds: Set<String>
    var inSheet = true

    @State private var newTag = ""
    @FocusState private var newTagFocused: Bool

    /// How many of the books have a tag, or have any tag at all.
    private struct TagState {
        var books: [Book] = []
        /// Lowercased tag -> number of the books that have it.
        var counts: [String: Int] = [:]
        var tagged = 0
        func count(_ tag: String) -> Int { counts[tag.lowercased()] ?? 0 }
    }

    var body: some View {
        if inSheet {
            NavigationStack {
                content
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("tags-done")
                        }
                    }
            }
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        let state = tagState()
        let total = state.books.count
        if total > 0 {
            Form {
                Section {
                    HStack {
                        TextField("New Tag", text: $newTag)
                            .focused($newTagFocused)
                            .submitLabel(.done)
                            .onSubmit(add)
                            .accessibilityIdentifier("tags-new")
                        Button("Add", action: add)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    // Not a real tag: it clears every tag from the books, and is never saved.
                    row(count: total - state.tagged, of: total) {
                        Label("No Tags", systemImage: "tag.slash")
                            .foregroundStyle(.secondary)
                    } action: {
                        model.editTags(bookIds, .clear)
                    }
                    .accessibilityIdentifier("tags-none")
                    ForEach(allTags(state), id: \.self) { tag in
                        let count = state.count(tag)
                        row(count: count, of: total) {
                            Label(tag, systemImage: "tag")
                                .foregroundStyle(.primary)
                        } action: {
                            // All have it: take it off. Some or none: add it to every book.
                            model.editTags(bookIds, count == total ? .remove(tag) : .add(tag))
                        }
                    }
                } footer: {
                    Text("Tags sync to your other devices. Rename or delete a tag by long-pressing it in the sidebar.")
                }
            }
            .navigationTitle(total == 1 ? "Tags" : "Tags · \(total) Books")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Book Not Found", systemImage: "book.closed")
        }
    }

    /// A row with a checkmark when all the books match, a dash and "3 of 12" when some do.
    private func row(count: Int, of total: Int, @ViewBuilder label: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                label()
                Spacer()
                if count == total {
                    Image(systemName: "checkmark").foregroundStyle(Color.primary)
                } else if count > 0 {
                    Text("\(count) of \(total)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Image(systemName: "minus").foregroundStyle(Color.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(count == total ? .isSelected : [])
        .accessibilityValue(count == total || count == 0 ? "" : "\(count) of \(total)")
    }

    private func tagState() -> TagState {
        var state = TagState()
        state.books = bookIds.compactMap { model.book(id: $0) }
        for book in state.books {
            if !book.tags.isEmpty { state.tagged += 1 }
            for tag in Set(book.tags.map { $0.lowercased() }) { state.counts[tag, default: 0] += 1 }
        }
        return state
    }

    /// Every tag in the library, plus the books' own (in case they are not counted yet).
    private func allTags(_ state: TagState) -> [String] {
        var names = model.summary.tags.map(\.name)
        var seen = Set(names.map { $0.lowercased() })
        for book in state.books {
            for tag in book.tags where seen.insert(tag.lowercased()).inserted { names.append(tag) }
        }
        return names.naturallySorted()
    }

    private func add() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        model.editTags(bookIds, .add(tag))
        newTag = ""
    }
}
