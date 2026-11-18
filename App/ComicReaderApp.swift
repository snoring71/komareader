import SwiftUI

@main
struct ComicReaderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Black-and-white switches instead of green (#55).
                .toggleStyle(MonoToggleStyle())
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        model.rescanSoon()
                    } else {
                        LibraryPosition.flush()
                        // The page on disk before iOS can end the app (#66).
                        model.flushProgress()
                    }
                }
        }
    }
}
