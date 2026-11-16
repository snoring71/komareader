import SwiftUI
import UIKit

/// The book open in the reader, so the next launch reopens it on the same page (#66).
///
/// Any relaunch reopens it, including after the user swipes the app away (decided with Zach,
/// 2026-11-16): on iPadOS 26 a swipe-away ends the app but the next launch gets the same scene
/// session back with no "discarded" callback, so it cannot be told apart from iOS ending the app.
/// Closing the reader first is how to land on the library. A first version used `@SceneStorage`.
@MainActor
enum ReaderRestore {
    private static let bookKey = "reader.restore.book"

    static var isEnabled: Bool { LibraryPosition.isEnabled }

    /// The book to reopen at launch, if one was open.
    static var savedBook: String? {
        isEnabled ? UserDefaults.standard.string(forKey: bookKey) : nil
    }

    /// Called whenever the reader opens or closes (nil).
    static func note(bookId: String?) {
        guard isEnabled else { return }
        if let bookId {
            UserDefaults.standard.set(bookId, forKey: bookKey)
        } else if UIApplication.shared.applicationState != .background {
            // Only a close the user made in the app. The reader closing because its window
            // went away in the background keeps the book.
            clear()
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookKey)
    }
}
