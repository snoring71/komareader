import SwiftUI

@main
struct ComicReaderApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Black-and-white switches instead of green (#55).
                .toggleStyle(MonoToggleStyle())
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // Only after the app was really away (it comes back through inactive).
                        // Pulling down Control Center or the notifications, or a system alert,
                        // makes it inactive for a moment, and a rescan reads the whole library
                        // folder and its records.
                        if wasInBackground { model.rescanSoon() }
                        wasInBackground = false
                    } else {
                        if phase == .background { wasInBackground = true }
                        LibraryPosition.flush()
                        // The page on disk before iOS can end the app (#66).
                        model.flushProgress()
                    }
                }
        }
    }
}
