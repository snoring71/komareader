import SwiftUI

/// Open from the shelf (#127): the cover tapped in the library grows into the reader, and the
/// reader shrinks back onto it when the book closes. Built on SwiftUI's zoom transition: the
/// cover is the transition's source and the reader's full-screen cover zooms from it.
enum ShelfZoom {
    static let settingKey = "reader.openFromShelf"

    /// On unless turned off in Settings › Reading.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }
}

extension EnvironmentValues {
    /// The namespace the library's covers and the reader zoom in (nil: no zoom).
    @Entry var shelfZoom: Namespace.ID?
}

/// Marks a cover as where its book opens from.
struct ShelfZoomSource: ViewModifier {
    @Environment(\.shelfZoom) private var namespace
    let id: String

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// On the reader: zooms from the cover it was opened from, when there is one.
struct ShelfZoomDestination: ViewModifier {
    let sourceID: String?
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if let sourceID {
            content
                .navigationTransition(.zoom(sourceID: sourceID, in: namespace))
                // The reader's own swipes and pinches page and zoom; the zoom transition's drag
                // and pinch to dismiss would fight them. Swipe up still closes the book.
                .interactiveDismissDisabled()
        } else {
            content
        }
    }
}
