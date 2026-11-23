import SwiftUI

/// Open from the shelf (#127): the cover tapped in the library grows into the reader, and
/// shrinks back onto it when the book closes.
///
/// Drawn here rather than with SwiftUI's zoom transition: that one scales the whole library
/// down behind the reader and back up as it closes, so the grid moved. Here the library never
/// moves: the reader is presented and dismissed without animation, and a copy of the cover
/// flies between the cell and the screen above it while the reader fades in or out.
enum ShelfZoom {
    static let settingKey = "reader.openFromShelf"

    /// On unless turned off in Settings › Reading.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    /// Where each cover on screen is, in the window, by cell (see `ShelfZoomSource`). Kept
    /// out of observation: it changes on every scroll and nothing redraws from it.
    @MainActor static var frames: [String: CGRect] = [:]

    static let duration = 0.38
    static let animation = Animation.smooth(duration: duration)
}

extension EnvironmentValues {
    /// Closes the reader by shrinking it back onto its cover, when it was opened from one.
    @Entry var shelfZoomClose: (() -> Void)?
}

/// Notes where a cover is, so the reader can grow out of it and return to it.
struct ShelfZoomSource: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                ShelfZoom.frames[id] = frame
            }
            .onDisappear { ShelfZoom.frames[id] = nil }
    }
}

/// Wraps the reader: the cover flying in when it opens, and out when it closes.
struct ShelfZoomContainer<Content: View>: View {
    @Environment(AppModel.self) private var model
    let bookId: String
    let content: Content

    /// 0: the cover sits on its cell; 1: it fills the screen as the reader shows it.
    @State private var progress: CGFloat
    @State private var readerOpacity: Double
    @State private var flying: Bool
    /// The cell, for this flight.
    @State private var source: CGRect?
    @State private var closing = false

    /// `from`: the cell the book was opened from, if any; the first frame already starts there.
    init(bookId: String, from cell: CGRect?, @ViewBuilder content: () -> Content) {
        self.bookId = bookId
        self.content = content()
        _source = State(initialValue: cell)
        _flying = State(initialValue: cell != nil)
        _progress = State(initialValue: cell == nil ? 1 : 0)
        _readerOpacity = State(initialValue: cell == nil ? 1 : 0)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                content
                    .opacity(readerOpacity)
                    .environment(\.shelfZoomClose, model.openedFrom == nil ? nil : { close() })
                if flying, let source {
                    let origin = geo.frame(in: .global).origin
                    let cell = source.offsetBy(dx: -origin.x, dy: -origin.y)
                    let rect = Self.interpolate(cell, Self.fitted(cell.size, in: geo.size), progress)
                    cover
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4 + 2 * (1 - progress), style: .continuous))
                        .shadow(color: .black.opacity(0.35 * progress), radius: 20 * progress)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        // The library shows around the flying cover.
        .presentationBackground(.clear)
        .onAppear(perform: open)
    }

    private var cover: some View {
        CoverImage(url: model.thumbnails[bookId], title: "", revision: model.coverRevision[bookId] ?? 0)
    }

    private func open() {
        guard flying else { return }
        withAnimation(ShelfZoom.animation) {
            progress = 1
            readerOpacity = 1
        } completion: {
            flying = false
        }
    }

    /// Shrinks back onto the cover (where its cell is now), then closes without animation.
    private func close() {
        guard !closing else { return }
        closing = true
        // The library takes the book's new progress now, behind the reader, so a book that
        // moves (to the front of Up Next) has moved before the library shows, and the cover
        // flies to where its cell is now.
        model.applyReadingProgress()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            flyHome()
        }
    }

    private func flyHome() {
        guard let id = model.openedFrom, let frame = ShelfZoom.frames[id] else {
            // The cell has gone (scrolled away, or another book opened from the last page):
            // the reader fades out over the library.
            withAnimation(.easeOut(duration: 0.25)) { readerOpacity = 0 } completion: { finish() }
            return
        }
        source = frame
        progress = 1
        flying = true
        withAnimation(ShelfZoom.animation) {
            progress = 0
            readerOpacity = 0
        } completion: {
            finish()
        }
    }

    private func finish() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { model.openBook = nil }
    }

    /// The cover's shape fitted to the screen, centred.
    static func fitted(_ shape: CGSize, in screen: CGSize) -> CGRect {
        guard shape.width > 0, shape.height > 0 else { return CGRect(origin: .zero, size: screen) }
        let scale = min(screen.width / shape.width, screen.height / shape.height)
        let size = CGSize(width: shape.width * scale, height: shape.height * scale)
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
    }

    static func interpolate(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }
}
