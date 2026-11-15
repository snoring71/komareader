import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    @Environment(\.sidebarToggle) private var sidebarToggle

    var body: some View {
        // Only precomputed counts are read here, so the sidebar redraws when a count changes,
        // not on every change to the books.
        let counts = model.summary.counts
        let pinned = model.pinnedFolders.filter { model.catalog.folders[$0] != nil }
        List {
            Section {
                row(.all, count: counts[.all])
                row(.continueReading, count: counts[.continueReading])
                row(.series, count: model.catalog.series.count)
                row(.folders, count: max(0, model.catalog.folders.count - 1)) // less the library folder itself
                row(.downloaded, count: counts[.downloaded])
            }
            if !pinned.isEmpty {
                Section("Pinned Folders") {
                    ForEach(pinned, id: \.self) { path in
                        row(.folder(path), count: model.catalog.folders[path]?.count)
                            .contextMenu {
                                Button("Unpin from Sidebar", systemImage: "pin.slash") { model.setPinned(path, false) }
                            }
                    }
                }
            }
            Section("Status") {
                row(.unread, count: counts[.unread])
                row(.reading, count: counts[.reading])
                row(.read, count: counts[.read])
                row(.favorites, count: counts[.favorites])
                row(.bookmarked, count: counts[.bookmarked])
                if let missing = counts[.missing] { row(.missing, count: missing) }
            }
            if !model.summary.tags.isEmpty {
                Section("Tags") {
                    ForEach(model.summary.tags) { tag in
                        row(.tag(tag.name), count: tag.count)
                            .contextMenu {
                                Button("Rename…", systemImage: "pencil") {
                                    newName = tag.name
                                    renaming = tag.name
                                }
                                Button("Delete Tag", systemImage: "trash", role: .destructive) { deleting = tag.name }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 38)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        // Let the panel's frosted background show through the bar and the list.
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close Sidebar", systemImage: "sidebar.left") { sidebarToggle.close() }
            }
        }
        .refreshable { await model.rescan() }
        .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Tag", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let old = renaming { model.renameTag(old, to: newName) } }
        } message: {
            Text("The tag is renamed on every book that has it.")
        }
        .confirmationDialog(deleting.map { "Delete the tag “\($0)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) { if let tag = deleting { model.deleteTag(tag) } }
        } message: {
            Text("The tag is removed from every book. The books are not deleted.")
        }
    }

    /// A row: icon, title and a pill with the count right after it, on a soft grey band when
    /// selected. Picking a row shows it in the library and puts the sidebar away.
    private func row(_ item: SidebarItem, count: Int?) -> some View {
        let selected = (model.selection ?? .all) == item
        return Button {
            if selected { sidebarToggle.close() } else { model.selection = item }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 22)
                Text(item.title)
                    .lineLimit(1)
                if let count, count > 0 {
                    Text(count, format: .number)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.primary.opacity(0.1) : Color.clear)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(item.title)")
    }
}
