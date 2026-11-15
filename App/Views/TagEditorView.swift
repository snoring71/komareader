import LibraryKit
import SwiftUI

/// A checklist of the library's tags for one book, with a field for a new tag. Shown as a sheet
/// from the library's long-press menu, or pushed from Book Info (`inSheet: false`).
struct TagEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bookId: String
    var inSheet = true

    @State private var newTag = ""
    @FocusState private var newTagFocused: Bool

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
        if let book = model.book(id: bookId) {
            Form {
                Section {
                    HStack {
                        TextField("New Tag", text: $newTag)
                            .focused($newTagFocused)
                            .submitLabel(.done)
                            .onSubmit { add(to: book) }
                            .accessibilityIdentifier("tags-new")
                        Button("Add") { add(to: book) }
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                let all = allTags(book)
                if !all.isEmpty {
                    Section {
                        ForEach(all, id: \.self) { tag in
                            let on = has(book, tag)
                            Button {
                                toggle(tag, on: book)
                            } label: {
                                HStack {
                                    Label(tag, systemImage: "tag")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if on { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .contentShape(Rectangle())
                            }
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    } footer: {
                        Text("Tags sync to your other devices. Rename or delete a tag by long-pressing it in the sidebar.")
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Book Not Found", systemImage: "book.closed")
        }
    }

    /// Every tag in the library, plus this book's own (in case they are not counted yet).
    private func allTags(_ book: Book) -> [String] {
        var names = model.summary.tags.map(\.name)
        for tag in book.tags where !names.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            names.append(tag)
        }
        return names.naturallySorted()
    }

    private func has(_ book: Book, _ tag: String) -> Bool {
        book.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    private func toggle(_ tag: String, on book: Book) {
        if has(book, tag) {
            model.setTags(book, book.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame })
        } else {
            model.setTags(book, book.tags + [tag])
        }
    }

    private func add(to book: Book) {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        // An existing tag typed in another case is used as it is spelled already.
        let existing = model.summary.tags.first { $0.name.caseInsensitiveCompare(tag) == .orderedSame }?.name
        if !has(book, tag) { model.setTags(book, book.tags + [existing ?? tag]) }
        newTag = ""
    }
}
