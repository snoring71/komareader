import OSLog
import SwiftUI
import UIKit

/// The book open in the reader, so a relaunch after iOS ended the app reopens it (#66), while a
/// relaunch after the user swiped the app away opens the library.
///
/// The book is saved with the id of the window's scene session. iOS keeps a session when it ends
/// the app itself, and discards it when the user swipes the window away in the app switcher: the
/// next launch then gets a new session id (so the saved book does not match), and iOS reports the
/// discarded session to `application(_:didDiscardSceneSessions:)`, which clears it too. A first
/// version used `@SceneStorage`. On Zach's iPad a swipe-away seemed to keep it; more likely the
/// app was not ended at all, only its window closed, and the reader was still open in memory
/// (see `AppModel.watchWindowsClosing`).
@MainActor
enum ReaderRestore {
    private static let bookKey = "reader.restore.book"
    private static let sessionKey = "reader.restore.session"
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ComicReader", category: "ReaderRestore")

    static var isEnabled: Bool { LibraryPosition.isEnabled }

    /// Called whenever the reader opens or closes (nil) in a window.
    static func note(bookId: String?, session: String) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        if let bookId {
            defaults.set(bookId, forKey: bookKey)
            defaults.set(session, forKey: sessionKey)
            log.notice("Reader open: \(bookId, privacy: .public) in session \(session, privacy: .public)")
        } else if UIApplication.shared.applicationState != .background, defaults.string(forKey: sessionKey) == session {
            // Only a close the user made in the app. The reader closing because its window
            // went away in the background keeps the marker.
            clear()
        }
    }

    /// The book to reopen in this window, if it was open in this same session.
    static func book(for session: String) -> String? {
        guard isEnabled, let saved = UserDefaults.standard.string(forKey: sessionKey) else { return nil }
        let book = UserDefaults.standard.string(forKey: bookKey)
        log.notice("Launch in session \(session, privacy: .public); saved session \(saved, privacy: .public), book \(book ?? "none", privacy: .public)")
        guard saved == session else { clear(); return nil }
        return book
    }

    /// Sessions the user closed (swiped away): their book is not reopened.
    static func discard(sessions: Set<String>) {
        log.notice("Discarded sessions: \(sessions.joined(separator: ", "), privacy: .public)")
        if let saved = UserDefaults.standard.string(forKey: sessionKey), sessions.contains(saved) { clear() }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookKey)
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }
}

/// Hears about scene sessions the user closed in the app switcher.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        ReaderRestore.log.notice("App launched (new process)")
        return true
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        let ids = Set(sceneSessions.map(\.persistentIdentifier))
        MainActor.assumeIsolated { ReaderRestore.discard(sessions: ids) }
    }
}

/// Reports the id of the scene session the view's window belongs to.
struct SceneSessionReader: UIViewRepresentable {
    let onChange: (String) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((String) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let id = window?.windowScene?.session.persistentIdentifier { onChange?(id) }
        }
    }
}
