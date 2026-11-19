import SwiftUI
import UIKit

// The long-press menu for library tiles (#71).
//
// SwiftUI's `.contextMenu` lifts the whole cell (icon row, cover and title) on the system's
// grey rounded platter, clipped to its own corner radius: the grey shows around the icons, the
// cover's corners change shape, and titles get cut off. UIKit's context menu lets the lifted
// preview have a clear background, no clipping, and a shadow shaped like the cover, so the
// tiles use it instead:
//
// - A grid installs one `UIContextMenuInteraction` on its scroll view (`liftMenuHost()`).
// - Each tile reports where it is, which part lifts (the icon row and cover, not the title),
//   where its cover is, and its menu (`liftMenu(...)`, `liftMenuPart(...)`).
// - On a long press the interaction finds the tile under the finger, draws the lifting part
//   into an image, and lifts that, while the tile itself hides until it drops back.
// - As the menu opens, the lifted tile grows into a large view of the cover beside it.

/// The tiles of one grid that have a long-press menu: where each one is, and what it lifts.
@MainActor @Observable
final class LiftMenuRegistry {
    struct Entry {
        /// The whole tile: a long press anywhere in it opens the menu.
        var frame: CGRect = .null
        /// The part that lifts (icon row and cover), in the grid's coordinates.
        var lift: CGRect = .null
        /// The cover itself, in the grid's coordinates: the lifted shadow follows it.
        var cover: CGRect = .null
        /// Cards peeking above the cover (series stacks), so their outline gets the shadow too.
        var stackCards = 0
        var cornerRadius: CGFloat = 0
        var menu: (@MainActor () -> UIMenu?)?
        var preview: (@MainActor () -> AnyView)?
        /// The full cover, shown large once the menu is open.
        var coverImage: (@MainActor () -> UIImage?)?
    }

    /// Names the grid's coordinate space, so tiles report frames in the host view's coordinates.
    let space = "lift-menu-\(UUID().uuidString)"
    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    /// The tile whose menu is open: it hides while its preview is lifted.
    var lifted: String?

    func update(_ id: String, _ change: (inout Entry) -> Void) {
        change(&entries[id, default: Entry()])
    }

    func remove(_ id: String) {
        entries[id] = nil
    }

    /// The tile under a point in the grid's coordinates. Tiles may overlap a little (a
    /// scrolled row's edge), so the smallest one wins.
    func id(at point: CGPoint) -> String? {
        entries
            .filter { $0.value.frame.contains(point) && $0.value.menu != nil }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
            .key
    }
}

extension EnvironmentValues {
    /// The grid's menu registry, for tiles inside a `liftMenuHost()`.
    @Entry var liftMenu: LiftMenuRegistry?
    /// True while a tile is being drawn into the lifted preview image. Glass and other
    /// effects that need the screen behind them are swapped for plain fills then.
    @Entry var liftRendering = false
}

extension View {
    /// Makes this view (the content of a scroll view) the host of its tiles' long-press menus.
    func liftMenuHost() -> some View {
        modifier(LiftMenuHostModifier())
    }

    /// The tile's long-press menu. Apply to the whole tile: a press anywhere in it opens the
    /// menu. `menu` is asked when the press happens and may return nil for no menu.
    /// `preview` draws the part that lifts; it is drawn with the environment it is given, so
    /// pass in what it needs.
    /// `cover` gives the cover image, which grows to a large view of it as the menu opens.
    func liftMenu(id: String, menu: @escaping @MainActor () -> UIMenu?, preview: @escaping @MainActor () -> AnyView,
                  cover: @escaping @MainActor () -> UIImage?) -> some View {
        modifier(LiftMenuItemModifier(id: id, menu: menu, preview: preview, cover: cover))
    }

    /// Marks the part of a tile that lifts, or its cover (see `LiftMenuPart`).
    func liftMenuPart(_ part: LiftMenuPart, id: String, cornerRadius: CGFloat = 0, stackCards: Int = 0) -> some View {
        modifier(LiftMenuPartModifier(id: id, part: part, cornerRadius: cornerRadius, stackCards: stackCards))
    }
}

enum LiftMenuPart {
    /// What lifts: hidden in place while the menu is open.
    case lift
    /// The cover inside it, whose outline gets the lifted shadow.
    case cover
}

private struct LiftMenuHostModifier: ViewModifier {
    @State private var registry = LiftMenuRegistry()

    func body(content: Content) -> some View {
        content
            .environment(\.liftMenu, registry)
            .coordinateSpace(.named(registry.space))
            .background(LiftMenuHostView(registry: registry))
    }
}

private struct LiftMenuItemModifier: ViewModifier {
    @Environment(\.liftMenu) private var registry
    let id: String
    let menu: @MainActor () -> UIMenu?
    let preview: @MainActor () -> AnyView
    let cover: @MainActor () -> UIImage?

    func body(content: Content) -> some View {
        if let registry {
            // Kept up to date on every redraw, so the menu reflects the tile as it is now.
            // Writing to the registry does not redraw anything (like `visible.books` in the grid).
            let _ = registry.update(id) {
                $0.menu = menu
                $0.preview = preview
                $0.coverImage = cover
            }
            content
                .onGeometryChange(for: CGRect.self) { [space = registry.space] in $0.frame(in: .named(space)) } action: { frame in
                    registry.update(id) { $0.frame = frame }
                }
                .onDisappear { registry.remove(id) }
        } else {
            content
        }
    }
}

private struct LiftMenuPartModifier: ViewModifier {
    @Environment(\.liftMenu) private var registry
    let id: String
    let part: LiftMenuPart
    let cornerRadius: CGFloat
    let stackCards: Int

    func body(content: Content) -> some View {
        if let registry {
            content
                .onGeometryChange(for: CGRect.self) { [space = registry.space] in $0.frame(in: .named(space)) } action: { frame in
                    registry.update(id) {
                        switch part {
                        case .lift: $0.lift = frame
                        case .cover:
                            $0.cover = frame
                            $0.cornerRadius = cornerRadius
                            $0.stackCards = stackCards
                        }
                    }
                }
                // The lifted copy stands in for it while the menu is open, as in Photos.
                .opacity(part == .lift && registry.lifted == id ? 0 : 1)
        } else {
            content
        }
    }
}

/// An empty view behind the grid that puts the context menu interaction on the scroll view
/// around it, and works out the lifted previews.
private struct LiftMenuHostView: UIViewRepresentable {
    let registry: LiftMenuRegistry

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.registry = registry
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        view.registry = registry
    }

    static func dismantleUIView(_ view: HostView, coordinator: ()) {
        view.detach()
    }

    final class HostView: UIView, UIContextMenuInteractionDelegate {
        var registry: LiftMenuRegistry?
        private var interaction: UIContextMenuInteraction?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                detach()
            } else if interaction == nil {
                // The nearest scroll view takes the touches over the tiles (this view is behind
                // them and takes none). Its own scrolling is unaffected.
                var target = superview
                while let view = target, !(view is UIScrollView) { target = view.superview }
                guard let host = target ?? superview else { return }
                let interaction = UIContextMenuInteraction(delegate: self)
                host.addInteraction(interaction)
                self.interaction = interaction
            }
        }

        func detach() {
            if let interaction { interaction.view?.removeInteraction(interaction) }
            interaction = nil
        }

        // MARK: UIContextMenuInteractionDelegate

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            guard let registry else { return nil }
            let point = interaction.location(in: self)
            guard let id = registry.id(at: point), let entry = registry.entries[id], let menu = entry.menu?() else { return nil }
            // The lifted tile grows into a large view of its cover beside the menu.
            var large: UIContextMenuContentPreviewProvider?
            if let image = entry.coverImage?() {
                let screen = window?.bounds ?? self.bounds
                // The cover's shape in the grid, so a wide image is cropped the same way.
                let aspect = entry.cover.isNull || entry.cover.height == 0 ? nil : entry.cover.width / entry.cover.height
                large = { LargeCoverController(image: image, aspect: aspect, bounds: screen) }
            }
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: large) { _ in menu }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            // The lifted copy starts exactly over the tile, so the tile hides now, before the
            // zoom starts: otherwise both show while it grows, a double image.
            let preview = preview(for: identifier)
            if preview != nil { registry?.lifted = identifier as? String }
            return preview
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            // Back to where the tile is now (an action may have moved it); none if it left.
            preview(for: identifier)
        }

        /// How long the copy takes to shrink back into the tile, about. The tile shows again at
        /// the end of it, at once and under the landing copy: not before (two covers, one
        /// shrinking past the other) and not after (the shadow comes back late). Not faded in:
        /// with the copy fading out at the same time, the two together flickered.
        private static let landing: TimeInterval = 0.28

        private func showTile(_ id: String?) {
            guard let registry, registry.lifted == id else { return }
            registry.lifted = nil
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionAnimating?) {
            registry?.lifted = configuration.identifier as? String
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    willEndFor configuration: UIContextMenuConfiguration,
                                    animator: UIContextMenuInteractionAnimating?) {
            let id = configuration.identifier as? String
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.landing) { [weak self] in
                self?.showTile(id)
            }
            // At the latest once the copy has landed.
            animator?.addCompletion { [weak self] in self?.showTile(id) }
            if animator == nil { showTile(id) }
        }

        /// The lifting part of a tile drawn into an image, on a clear background, with a
        /// shadow shaped like its cover.
        private func preview(for identifier: NSCopying) -> UITargetedPreview? {
            guard let id = identifier as? String, let entry = registry?.entries[id],
                  let draw = entry.preview, !entry.lift.isNull, !entry.lift.isEmpty else { return nil }
            let lift = entry.lift
            let renderer = ImageRenderer(content: draw().frame(width: lift.width, height: lift.height))
            renderer.scale = traitCollection.displayScale
            renderer.isOpaque = false
            guard let image = renderer.uiImage else { return nil }

            let view = UIImageView(image: image)
            view.frame = CGRect(origin: .zero, size: lift.size)
            let parameters = UIPreviewParameters()
            // No platter: only what the tile draws shows, icons floating above the cover.
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(rect: view.bounds)
            if !entry.cover.isNull {
                parameters.shadowPath = Self.outline(cover: entry.cover.offsetBy(dx: -lift.minX, dy: -lift.minY),
                                                     radius: entry.cornerRadius, stackCards: entry.stackCards)
            }
            let target = UIPreviewTarget(container: self, center: CGPoint(x: lift.midX, y: lift.midY))
            return UITargetedPreview(view: view, parameters: parameters, target: target)
        }

        /// The cover's outline, plus the cards peeking above it (same geometry as `StackCards`).
        private static func outline(cover: CGRect, radius: CGFloat, stackCards: Int) -> UIBezierPath {
            let path = UIBezierPath(roundedRect: cover, cornerRadius: radius)
            let step = StackCards.peek / 2
            for level in stride(from: 1, through: min(stackCards, 2), by: 1) {
                let card = cover
                    .insetBy(dx: step * 1.5 * CGFloat(level), dy: 0)
                    .offsetBy(dx: 0, dy: -step * CGFloat(level))
                path.append(UIBezierPath(roundedRect: card, cornerRadius: radius))
            }
            return path
        }
    }
}

/// Builds the UIKit menus' items.
enum LiftMenuItems {
    static func action(_ title: String, _ symbol: String, destructive: Bool = false,
                       identifier: String? = nil, _ handler: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: title, image: UIImage(systemName: symbol),
                              attributes: destructive ? .destructive : []) { _ in handler() }
        if let identifier { action.accessibilityIdentifier = identifier }
        return action
    }

    /// A group of items with lines above and below it, like a `Section` in a SwiftUI menu.
    static func section(_ children: [UIMenuElement]) -> UIMenu {
        UIMenu(title: "", options: .displayInline, children: children)
    }

    /// Pin to Sidebar or Unpin from Sidebar, for a folder or a series (#72).
    @MainActor static func pin(_ item: SidebarItem, model: AppModel) -> UIMenu {
        let pinned = model.isPinned(item)
        return UIMenu(title: "", children: [
            action(pinned ? "Unpin from Sidebar" : "Pin to Sidebar", pinned ? "pin.slash" : "pin") {
                model.setPinned(item, !pinned)
            },
        ])
    }
}

/// A cover shown large while a tile's long-press menu is open (#71): as big as fits in about
/// half the screen's height, and up to half its width, cropped like the grid's cover.
private final class LargeCoverController: UIViewController {
    private let image: UIImage

    /// `aspect` is the cover's shape in the grid (width / height); the image fills it, cropped
    /// in the middle as in the grid. Nil uses the image's own shape.
    init(image: UIImage, aspect: CGFloat?, bounds: CGRect) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        let maxSize = CGSize(width: bounds.width * 0.5, height: bounds.height * 0.55)
        let aspect = aspect ?? (image.size.height > 0 ? image.size.width / image.size.height : 2.0 / 3.0)
        var size = CGSize(width: maxSize.height * aspect, height: maxSize.height)
        if size.width > maxSize.width { size = CGSize(width: maxSize.width, height: maxSize.width / aspect) }
        preferredContentSize = CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.accessibilityIgnoresInvertColors = true
        self.view = view
    }
}
