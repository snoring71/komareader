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
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SidebarSection(nil) {
                        row(.all, count: counts[.all])
                        row(.continueReading, count: counts[.continueReading])
                        row(.series, count: model.catalog.series.count)
                        row(.folders, count: max(0, model.catalog.folders.count - 1)) // less the library folder itself
                        row(.downloaded, count: counts[.downloaded])
                    }
                    if !pinned.isEmpty {
                        SidebarSection("Pinned Folders") {
                            ForEach(pinned, id: \.self) { path in
                                row(.folder(path), count: model.catalog.folders[path]?.count)
                                    .contextMenu {
                                        Button("Unpin from Sidebar", systemImage: "pin.slash") { model.setPinned(path, false) }
                                    }
                            }
                        }
                    }
                    SidebarSection("Status") {
                        row(.unread, count: counts[.unread])
                        row(.reading, count: counts[.reading])
                        row(.read, count: counts[.read])
                        row(.favorites, count: counts[.favorites])
                        row(.bookmarked, count: counts[.bookmarked])
                        if let missing = counts[.missing] { row(.missing, count: missing) }
                    }
                    if !model.summary.tags.isEmpty {
                        SidebarSection("Tags") {
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
                .padding(.bottom, 24)
            }
            .refreshable { await model.rescan() }
        }
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

    /// "Library" and the button that puts the sidebar away.
    private var header: some View {
        ZStack {
            Text("Library").font(.headline)
            HStack {
                Spacer()
                Button {
                    sidebarToggle.close()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close Sidebar")
                .accessibilityIdentifier("sidebar-close")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
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
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            // Selected: a plain band across the whole panel, edge to edge.
            .background(selected ? Color.primary.opacity(0.1) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(item.title)")
    }
}

/// A titled group of sidebar rows, without the system list's lines or rounded corners.
private struct SidebarSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if let title {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        }
        content
    }
}
