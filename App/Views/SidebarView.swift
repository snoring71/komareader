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
        // The count is drawn in the label, not with `.badge`, so it can switch to the inverse
        // color on the selected row's black or white highlight (#55).
        Label {
            SidebarTitle(title: item.title, count: count ?? 0)
        } icon: {
            Image(systemName: item.systemImage)
        }
            .tag(item)
            .accessibilityIdentifier("sidebar-\(item.title)")
    }
}

/// A sidebar row's title with its count on the right, in the inverse color on the selected
/// row's highlight.
private struct SidebarTitle: View {
    let title: String
    let count: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        HStack {
            Text(title)
                .foregroundStyle(selected ? Color.onAccent : Color.primary)
            Spacer(minLength: 8)
            if count > 0 {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.onAccent.opacity(0.75) : Color.secondary)
            }
        }
    }
}

/// Sidebar icons in black (light mode) or white (dark mode) instead of the accent color. The
/// selected row's highlight is the accent (black or white), so there they take the inverse.
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
            icon.foregroundStyle(prominence == .increased ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
        }
    }
}
