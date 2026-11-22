import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?
    /// A reading list being renamed or deleted (#83).
    @State private var renamingList: String?
    @State private var deletingList: String?
    @Environment(\.sidebarToggle) private var sidebarToggle

    var body: some View {
        // Only precomputed counts are read here, so the sidebar redraws when a count changes,
        // not on every change to the books.
        let counts = model.summary.counts
        let pinned = model.pinned.filter { model.pinStillExists($0) }
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SidebarSection(nil) {
                        row(.all, count: counts[.all])
                        row(.continueReading, count: counts[.continueReading])
                        row(.upNext, count: counts[.upNext])
                        row(.series, count: model.catalog.series.count)
                        // Less the "Unknown" group, which is not a name (#78).
                        row(.authors, count: model.catalog.authors.filter { !$0.name.isEmpty }.count)
                        row(.publishers, count: model.catalog.publishers.filter { !$0.name.isEmpty }.count)
                        row(.folders, count: max(0, model.catalog.folders.count - 1)) // less the library folder itself
                        row(.downloaded, count: counts[.downloaded])
                    }
                    if !pinned.isEmpty {
                        // Folders and series together, in the order they were pinned (#72).
                        SidebarSection("Pinned") {
                            ForEach(pinned, id: \.self) { item in
                                row(item, count: pinCount(item))
                                    .contextMenu {
                                        Button("Unpin from Sidebar", systemImage: "pin.slash") { model.setPinned(item, false) }
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
                    let lists = model.readingLists
                    if !lists.isEmpty {
                        SidebarSection("Reading Lists") {
                            ForEach(Array(lists.enumerated()), id: \.element.id) { offset, list in
                                let item = SidebarItem.readingList(list.id)
                                row(item, count: list.bookIds?.count ?? 0)
                                    .contextMenu {
                                        Button("Rename…", systemImage: "pencil") {
                                            newName = list.name
                                            renamingList = list.id
                                        }
                                        if offset > 0 {
                                            Button("Move Up", systemImage: "arrow.up") { model.moveList(list.id, by: -1) }
                                        }
                                        if offset < lists.count - 1 {
                                            Button("Move Down", systemImage: "arrow.down") { model.moveList(list.id, by: 1) }
                                        }
                                        let pinned = model.isPinned(item)
                                        Button(pinned ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: pinned ? "pin.slash" : "pin") {
                                            model.setPinned(item, !pinned)
                                        }
                                        Button("Delete List", systemImage: "trash", role: .destructive) { deletingList = list.id }
                                    }
                            }
                        }
                    }
                    let smart = model.smartLists
                    SidebarSection("Smart Lists") {
                        ForEach(Array(smart.enumerated()), id: \.element.id) { offset, list in
                            let item = SidebarItem.smartList(list.id)
                            row(item, count: model.smartCounts[list.id])
                                .contextMenu {
                                    Button("Edit…", systemImage: "pencil") {
                                        model.smartEditor = .init(listId: list.id, filter: list.filter ?? LibraryFilter())
                                    }
                                    if offset > 0 {
                                        Button("Move Up", systemImage: "arrow.up") { model.moveList(list.id, by: -1) }
                                    }
                                    if offset < smart.count - 1 {
                                        Button("Move Down", systemImage: "arrow.down") { model.moveList(list.id, by: 1) }
                                    }
                                    let pinned = model.isPinned(item)
                                    Button(pinned ? "Unpin from Sidebar" : "Pin to Sidebar", systemImage: pinned ? "pin.slash" : "pin") {
                                        model.setPinned(item, !pinned)
                                    }
                                    Button("Delete List", systemImage: "trash", role: .destructive) { deletingList = list.id }
                                }
                        }
                        Button {
                            model.smartEditor = .init(listId: nil, filter: LibraryFilter(rules: [.init(.status, .isAnyOf, ["unread"])]))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus").frame(width: 22)
                                Text("New Smart List…")
                                Spacer(minLength: 0)
                            }
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 18)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebar-new-smart-list")
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
        .alert("Rename Reading List", isPresented: Binding(get: { renamingList != nil }, set: { if !$0 { renamingList = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let id = renamingList { model.renameList(id, to: newName) } }
        }
        .confirmationDialog(deletingList.map { "Delete the list “\(SidebarItem.readingList($0).title)”?" } ?? "",
                            isPresented: Binding(get: { deletingList != nil }, set: { if !$0 { deletingList = nil } }), titleVisibility: .visible) {
            Button("Delete List", role: .destructive) { if let id = deletingList { model.deleteList(id) } }
        } message: {
            Text("The list is deleted on all your devices. The books in it are not.")
        }
        .confirmationDialog(deleting.map { "Delete the tag “\($0)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) { if let tag = deleting { model.deleteTag(tag) } }
        } message: {
            Text("The tag is removed from every book. The books are not deleted.")
        }
    }

    /// How many books a pinned folder or series holds.
    private func pinCount(_ item: SidebarItem) -> Int? {
        switch item {
        case .folder(let path): return model.catalog.folders[path]?.count
        case .seriesNamed(let name):
            return model.catalog.series.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.books.count
        case .author(let name):
            return model.catalog.authors.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.books.count
        case .publisher(let name):
            return model.catalog.publishers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.books.count
        case .readingList(let id): return model.lists.list(id)?.bookIds?.count
        case .smartList(let id): return model.smartCounts[id]
        default: return nil
        }
    }

    private static let countPill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.2) : UIColor.systemGray
    })

    /// "Library" and the button that puts the sidebar away.
    private var header: some View {
        ZStack {
            Text("Library").font(.title3.weight(.semibold))
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
        // A little space before the first row's highlight.
        .padding(.bottom, 8)
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
                        // White text on a grey pill: mid grey in light mode (dark enough for
                        // white), a faint light grey in dark mode.
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Self.countPill))
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
            // A bit larger than the rows under it, left-aligned.
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
        }
        content
    }
}
