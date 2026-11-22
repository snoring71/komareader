import ComicCore
import LibraryKit
import SwiftUI

/// Add to Reading List… (#83): New List at the top, then the lists, each with its count. A
/// tap adds the books to the end of the list (books already in it stay where they are).
struct ReadingListPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bookIds: [String]
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        name = ""
                        naming = true
                    } label: {
                        Label("New Reading List…", systemImage: "plus")
                    }
                    .tint(.primary)
                    .accessibilityIdentifier("list-new")
                }
                Section {
                    ForEach(model.readingLists) { list in
                        let have = Set(list.bookIds ?? [])
                        let all = bookIds.allSatisfy(have.contains)
                        Button {
                            model.addToReadingList(list.id, bookIds: bookIds)
                            dismiss()
                        } label: {
                            HStack {
                                Label(list.name, systemImage: "list.number")
                                Spacer()
                                if all {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                                Text("\(list.bookIds?.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .tint(.primary)
                        .disabled(all)
                        .accessibilityIdentifier("list-\(list.name)")
                    }
                } footer: {
                    if model.readingLists.isEmpty {
                        Text("A reading list holds books in an order you choose, across series and folders.")
                    }
                }
            }
            .navigationTitle(bookIds.count == 1 ? "Add to Reading List" : "Add \(bookIds.count) Books to a List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New Reading List", isPresented: $naming) {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("list-name")
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if model.newReadingList(named: name, with: bookIds) != nil { dismiss() }
                }
            } message: {
                Text(bookIds.count == 1 ? "The book is added to the new list." : "The books are added to the new list.")
            }
        }
    }
}

/// Reorder… in a reading list (#83): drag books into order, or swipe to take one out of the list.
struct ReadingListOrderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let listId: String
    @State private var ids: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(ids, id: \.self) { id in
                    let book = model.book(id: id)
                    HStack(spacing: 12) {
                        CoverImage(url: model.thumbnails[id], title: book?.title ?? "", revision: model.coverRevision[id] ?? 0)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book?.title ?? "Missing Book").lineLimit(1)
                            if book?.isMissing == true {
                                Text("File missing").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .opacity(book?.isMissing == true ? 0.5 : 1)
                }
                .onMove { ids.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { ids.remove(atOffsets: $0) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder \(SidebarItem.readingList(listId).title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.setListBooks(listId, ids)
                        dismiss()
                    }
                    .accessibilityIdentifier("list-order-done")
                }
            }
            .onAppear { ids = model.lists.list(listId)?.bookIds ?? [] }
        }
    }
}

/// Five stars to tap for a rating (#84), black and white like the app's other marks. Tapping
/// the current rating again removes it.
struct StarRating: View {
    let value: Int?
    var size: CGFloat = 20
    let onChange: (Int?) -> Void

    var body: some View {
        HStack(spacing: size * 0.3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onChange(value == star ? nil : star)
                } label: {
                    Image(systemName: (value ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
                .accessibilityAddTraits(value == star ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rating-stars")
    }
}
