import Foundation

/// Where the user was in the library (the sidebar item, the folders or series opened from it,
/// and the book at the top of the grid), saved on this device so a relaunch opens in the same
/// place.
@MainActor
enum LibraryPosition {
    private static let selectionKey = "library.selection"
    private static let pathKey = "library.path"
    private static let anchorListKey = "library.anchorList"
    private static let anchorBookKey = "library.anchorBook"

    /// The demo library (UI tests) always starts on All Books.
    static var isEnabled: Bool { !AppModel.isDemo }

    static func save(selection: SidebarItem?, path: [SidebarItem]) {
        guard isEnabled else { return }
        let defaults = UserDefaults.standard
        defaults.set(selection?.storageKey, forKey: selectionKey)
        defaults.set(path.map(\.storageKey), forKey: pathKey)
    }

    static func restore() -> (selection: SidebarItem, path: [SidebarItem], anchor: Anchor?)? {
        guard isEnabled, let key = UserDefaults.standard.string(forKey: selectionKey),
              let selection = SidebarItem(storageKey: key) else { return nil }
        let path = (UserDefaults.standard.stringArray(forKey: pathKey) ?? []).compactMap(SidebarItem.init(storageKey:))
        var anchor: Anchor?
        if let list = UserDefaults.standard.string(forKey: anchorListKey), let book = UserDefaults.standard.string(forKey: anchorBookKey) {
            anchor = Anchor(list: list, bookId: book)
        }
        return (selection, path, anchor)
    }

    /// The book at the top of a grid (`list` is the grid's `SidebarItem.storageKey`).
    struct Anchor: Equatable {
        let list: String
        let bookId: String
    }

    /// Kept in memory while scrolling and written out by `flush`, since the visible books
    /// change many times a second during a fast scroll.
    private static var pending: Anchor?

    static func noteTopBook(_ anchor: Anchor) {
        guard isEnabled else { return }
        pending = anchor
    }

    /// Writes the latest scroll position. Called when the app leaves the foreground.
    static func flush() {
        guard let anchor = pending else { return }
        pending = nil
        UserDefaults.standard.set(anchor.list, forKey: anchorListKey)
        UserDefaults.standard.set(anchor.bookId, forKey: anchorBookKey)
    }
}
