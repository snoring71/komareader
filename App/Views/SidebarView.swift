import LibraryKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let folders = FolderNode.tree(from: model.books)
        List(selection: $model.selection) {
            Section {
                row(.all)
                row(.continueReading)
            }
            Section("Status") {
                row(.unread)
                row(.reading)
                row(.read)
                if model.books.contains(where: \.isMissing) { row(.missing) }
            }
            if !folders.isEmpty {
                Section("Folders") {
                    OutlineGroup(folders, children: \.children) { node in
                        Label(node.name, systemImage: "folder")
                            .badge(node.count)
                            .tag(SidebarItem.folder(node.id))
                    }
                }
            }
        }
        .navigationTitle(model.libraryName)
        .refreshable { await model.rescan() }
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .badge(model.books.filter(item.includes).count)
            .tag(item)
            .accessibilityIdentifier("sidebar-\(item.title)")
    }
}
