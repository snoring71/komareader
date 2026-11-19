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
//   into an image, and lifts that, while the tile itself hides until the menu closes.

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
    func liftMenu(id: String, menu: @escaping @MainActor () -> UIMenu?, preview: @escaping @MainActor () -> AnyView) -> some View {
        modifier(LiftMenuItemModifier(id: id, menu: menu, preview: preview))
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

    func body(content: Content) -> some View {
        if let registry {
            // Kept up to date on every redraw, so the menu reflects the tile as it is now.
            // Writing to the registry does not redraw anything (like `visible.books` in the grid).
            let _ = registry.update(id) {
                $0.menu = menu
                $0.preview = preview
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
            guard let id = registry.id(at: point), let menu = registry.entries[id]?.menu?() else { return nil }
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { _ in menu }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            preview(for: identifier)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
            // Back to where the tile is now (an action may have moved it); none if it left.
            preview(for: identifier)
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
            let show = { [weak self] in
                if self?.registry?.lifted == id { self?.registry?.lifted = nil }
            }
            if let animator { animator.addCompletion(show) } else { show() }
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
