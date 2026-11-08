import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView()
            case .needsFolder:
                WelcomeView()
            case .ready:
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    NavigationStack {
                        LibraryGridView(item: model.selection ?? .all)
                    }
                }
            }
        }
        .fullScreenCover(item: $model.openBook) { open in
            ReaderScreen(book: open.book, source: open.source)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        ContentUnavailableView {
            Label("Choose Your Comics Folder", systemImage: "books.vertical")
        } description: {
            Text("Pick the iCloud Drive folder that holds your comics, such as iCloud Drive › Booklover. Books stay where they are; nothing in the folder is changed.")
        } actions: {
            Button("Choose Folder…") { showPicker = true }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Button("Use the Comic Reader Folder") { Task { await model.useAppFolder() } }
                .buttonStyle(.glass)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.choose(folder: url) }
            }
        }
    }
}
