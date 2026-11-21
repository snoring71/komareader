import SwiftUI

/// Where each library view was scrolled to, kept for the rest of the session (#105), so going
/// back to All Books, a tag, a pinned folder or the Series grid finds it where it was left.
/// Only the view on screen at the end is saved across a relaunch (`LibraryPosition`).
///
/// Positions are kept by the item at the top of the grid rather than a pixel offset, so they
/// survive cover size and Show Titles changes. Kept in memory only and never observed, so
/// scrolling never redraws the library.
@MainActor
final class ScrollMemory {
    struct Spot: Equatable {
        /// The book, series or folder at the top of the grid.
        let id: String
        /// Where it was in the list, for when it has since gone (removed, or filtered out).
        /// Nil when not known (a position saved at the last launch).
        let index: Int?
    }

    private var spots: [String: Spot] = [:]

    func spot(for key: String) -> Spot? { spots[key] }

    /// Nil forgets the position: the view is back at the top.
    func set(_ spot: Spot?, for key: String) { spots[key] = spot }
}

/// One library grid's part in `ScrollMemory`: told what is on screen, it keeps the view's
/// position up to date, and puts the grid back there when the view comes back. A plain object
/// held in `@State`, since it changes on every row scrolled past.
@MainActor
final class ScrollKeeper {
    /// The ids in the grid, in order. Set on every draw of the grid.
    var ids: [String] = [] {
        didSet { order = nil }
    }
    /// True while a search narrows the grid. Positions are only noted in the full list, so
    /// coming back after a search returns to where the user was before searching.
    var isFiltered = false
    private var order: [String: Int]?
    private var top: String?
    private var scrolledDown = false
    private var restored = false
    /// True from the moment the grid is to go back to a saved spot until it has: what scrolls
    /// past in between is not where the user is.
    private var isRestoring = false

    /// The grid's visible ids (in any order) changed.
    func noteVisible(_ visible: [String], key: String, memory: ScrollMemory) {
        guard !isFiltered else { return }
        let order = gridOrder()
        top = visible.min { (order[$0] ?? .max) < (order[$1] ?? .max) }
        save(key: key, memory: memory)
    }

    /// Whether the grid is scrolled away from its top.
    func noteScrolledDown(_ down: Bool, key: String, memory: ScrollMemory) {
        guard !isFiltered, down != scrolledDown else { return }
        scrolledDown = down
        save(key: key, memory: memory)
    }

    private func save(key: String, memory: ScrollMemory) {
        guard !isRestoring else { return }
        guard scrolledDown, let top else {
            memory.set(nil, for: key)
            return
        }
        memory.set(.init(id: top, index: gridOrder()[top]), for: key)
    }

    private func gridOrder() -> [String: Int] {
        if let order { return order }
        var order: [String: Int] = [:]
        order.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() where order[id] == nil { order[id] = i }
        self.order = order
        return order
    }

    /// The id to scroll to for the saved position, or nil to stay at the top. A spot whose
    /// item has gone falls back to whatever is now at its place in the list.
    func target(for spot: ScrollMemory.Spot?) -> String? {
        guard let spot, !ids.isEmpty else { return nil }
        if let i = gridOrder()[spot.id] {
            return i == 0 ? nil : spot.id
        }
        guard let index = spot.index, index > 0 else { return nil }
        return ids[min(index, ids.count - 1)]
    }

    /// True the first time the view appears, so a view the navigation stack kept (and whose
    /// scroll position is still there) is not scrolled again.
    func takeFirstAppearance() -> Bool {
        defer { restored = true }
        return !restored
    }

    func beginRestore() { isRestoring = true }

    /// The grid has gone back to `spot` (nil: it is at the top, or was left where it was).
    func endRestore(at spot: ScrollMemory.Spot?, key: String, memory: ScrollMemory) {
        isRestoring = false
        memory.set(spot, for: key)
    }
}

/// An empty view at the very top of a remembered grid's scroll content, so a grid can go back
/// to its top (above Continue Reading and subfolders) after a search is cleared.
struct ScrollTopMarker: View {
    static let id = "scroll-top"

    var body: some View {
        Color.clear.frame(height: 0).id(Self.id)
    }
}

extension View {
    /// Keeps a library grid's scroll position for the session (#105) and puts it back when
    /// the view appears again. Coming back to the view from a folder or series opened on top
    /// of it clears its search (`clearSearch`) and returns to the spot in the full list.
    ///
    /// The grid's lazy stack needs `.scrollTargetLayout()` for the visible ids to arrive, and
    /// the scroll content starts with a `ScrollTopMarker`.
    func remembersScroll(_ keeper: ScrollKeeper, item: SidebarItem, ids: [String], isFiltered: Bool,
                         proxy: ScrollViewProxy, clearSearch: @escaping () -> Void,
                         onVisible: (([String]) -> Void)? = nil) -> some View {
        modifier(RemembersScroll(keeper: keeper, item: item, ids: ids, isFiltered: isFiltered,
                                 proxy: proxy, clearSearch: clearSearch, onVisible: onVisible))
    }
}

private struct RemembersScroll: ViewModifier {
    @Environment(AppModel.self) private var model
    let keeper: ScrollKeeper
    let item: SidebarItem
    let ids: [String]
    let isFiltered: Bool
    let proxy: ScrollViewProxy
    let clearSearch: () -> Void
    let onVisible: (([String]) -> Void)?

    func body(content: Content) -> some View {
        let _ = (keeper.ids = ids)
        let _ = (keeper.isFiltered = isFiltered)
        let memory = model.scrollMemory
        let key = item.storageKey
        content
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { visible in
                keeper.noteVisible(visible, key: key, memory: memory)
                onVisible?(visible)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top > 60
            } action: { _, down in
                keeper.noteScrolledDown(down, key: key, memory: memory)
            }
            .onAppear {
                guard keeper.takeFirstAppearance() else { return }
                restore(orTop: false)
            }
            .onChange(of: model.libraryPath.count) { old, new in
                // Back to this view from a folder or series opened on top of it: the search
                // goes, and the grid returns to where it was in the full list.
                guard new < old, new == depth, keeper.isFiltered else { return }
                keeper.isFiltered = false
                clearSearch()
                restore(orTop: true)
            }
    }

    /// How deep in the navigation stack this view is: 0 for the sidebar item itself.
    private var depth: Int {
        guard item != model.selection, let i = model.libraryPath.firstIndex(of: item) else { return 0 }
        return i + 1
    }

    /// Scrolls to the saved spot. `orTop`: with no saved spot, go to the top (after a search
    /// the grid may be scrolled anywhere); otherwise leave the grid where it is.
    private func restore(orTop: Bool) {
        let memory = model.scrollMemory
        let key = item.storageKey
        let spot = memory.spot(for: key)
        guard spot != nil || orTop else { return }
        let keeper = keeper
        let proxy = proxy
        keeper.beginRestore()
        Task { @MainActor in
            // Let the grid draw the full list first.
            await Task.yield()
            if let id = keeper.target(for: spot) {
                proxy.scrollTo(id, anchor: .top)
                keeper.endRestore(at: .init(id: id, index: spot?.index), key: key, memory: memory)
            } else {
                proxy.scrollTo(ScrollTopMarker.id, anchor: .top)
                keeper.endRestore(at: nil, key: key, memory: memory)
            }
        }
    }
}
