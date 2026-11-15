import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        @Bindable var model = model
        // Only precomputed counts are read here, so the sidebar redraws when a count changes,
        // not on every change to the books.
        let counts = model.summary.counts
        let pinned = model.pinnedFolders.filter { model.catalog.folders[$0] != nil }
        List(selection: $model.selection) {
            Section {
                row(.all, count: counts[.all])
                row(.continueReading, count: counts[.continueReading])
                row(.series, count: model.catalog.series.count)
                row(.folders, count: model.catalog.folders.count - 1)
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
        .labelStyle(SidebarLabelStyle())
        .navigationTitle(model.libraryName)
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

    private func row(_ item: SidebarItem, count: Int?) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .badge(count ?? 0)
            .tag(item)
            .accessibilityIdentifier("sidebar-\(item.title)")
    }
}

/// Sidebar icons in black (light mode) or white (dark mode) instead of the accent color, and
/// white on the selected row's highlight.
struct SidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            SidebarIcon(icon: configuration.icon)
        }
    }

    private struct SidebarIcon<Icon: View>: View {
        let icon: Icon
        @Environment(\.backgroundProminence) private var prominence

        var body: some View {
            icon.foregroundStyle(prominence == .increased ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
    }
}
