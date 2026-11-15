import ComicCore
import LibraryKit
import SwiftUI

/// One button (or readout) in the reader's menu bar. The bar draws whatever list it is given,
/// in groups split by thin dividers, so adding, removing or moving an option means editing
/// `ReaderBarItem.items(...)` and, for a new option, writing one small factory below it.
struct ReaderBarItem: Identifiable {
    /// Items of one group sit together; a divider separates groups.
    enum Group { case book, pages, reading, look, more }

    enum Behavior {
        /// Shows something about the book; not a button.
        case info
        /// Does something at once (toggles or steps to the next value).
        case action(() -> Void)
        /// Opens a small panel under the item. The panel is handed a closure that closes it.
        case panel((_ close: @escaping () -> Void) -> AnyView)
    }

    let id: String
    let group: Group
    /// Read by VoiceOver; should include the current value.
    let label: String
    let icon: AnyView
    let behavior: Behavior
    /// Drawn highlighted (a setting that is on, or changed from the plain page).
    var isOn = false
    /// The highlight colour when on; the accent colour if nil.
    var tint: Color?
    /// After an action, a word or two about the new value, shown briefly under the bar.
    var announcement: (() -> String)?
}

// MARK: - The items

extension ReaderBarItem {
    /// Everything in the bar, left to right.
    @MainActor
    static func items(state: ReaderState, book: Book, model: AppModel, onCrop: @escaping () -> Void) -> [ReaderBarItem] {
        [
            progress(state),
            favorite(book, model),
            bookmark(book, model),
            pageLayout(state),
            fit(state),
            crop(state, onCrop: onCrop),
            direction(state),
            background(state),
            adjustments(state),
            more(state),
        ]
    }

    @MainActor
    static func progress(_ state: ReaderState) -> ReaderBarItem {
        let last = state.currentPages.last ?? 0
        let fraction = state.pageCount > 1 ? Double(last) / Double(state.pageCount - 1) : 1
        let percent = Int((fraction * 100).rounded())
        return ReaderBarItem(id: "progress", group: .book, label: "\(percent) percent read",
                             icon: AnyView(ProgressRingIcon(fraction: fraction)), behavior: .info)
    }

    @MainActor
    static func favorite(_ book: Book, _ model: AppModel) -> ReaderBarItem {
        ReaderBarItem(id: "favorite", group: .book, label: book.favorite ? "Favorite, on" : "Favorite, off",
                      icon: AnyView(Image(systemName: book.favorite ? "heart.fill" : "heart").contentTransition(.symbolEffect(.replace))),
                      behavior: .action { model.setFavorite(book, !book.favorite) },
                      isOn: book.favorite, tint: .pink,
                      announcement: { book.favorite ? "Removed from Favorites" : "Added to Favorites" })
    }

    @MainActor
    static func bookmark(_ book: Book, _ model: AppModel) -> ReaderBarItem {
        ReaderBarItem(id: "bookmark", group: .book, label: book.bookmarked ? "Bookmarked, on" : "Bookmarked, off",
                      icon: AnyView(Image(systemName: book.bookmarked ? "bookmark.fill" : "bookmark").contentTransition(.symbolEffect(.replace))),
                      behavior: .action { model.setBookmarked(book, !book.bookmarked) },
                      isOn: book.bookmarked, tint: .orange,
                      announcement: { book.bookmarked ? "Bookmark Removed" : "Bookmarked" })
    }

    @MainActor
    static func pageLayout(_ state: ReaderState) -> ReaderBarItem {
        let layout = state.isShowingLandscape ? state.landscapeLayout : state.portraitLayout
        return ReaderBarItem(id: "layout", group: .pages, label: "Page Layout, \(layout.title)",
                             icon: AnyView(PageLayoutIcon(layout: layout, split: state.splitDoublePages)),
                             behavior: .panel { _ in AnyView(PageLayoutPanel(state: state)) })
    }

    @MainActor
    static func fit(_ state: ReaderState) -> ReaderBarItem {
        let all = ReaderOptions.Fit.allCases
        return ReaderBarItem(id: "fit", group: .pages, label: state.fit.title,
                             icon: AnyView(FitIcon(fit: state.fit)),
                             behavior: .action {
                                 let next = all[((all.firstIndex(of: state.fit) ?? 0) + 1) % all.count]
                                 state.change { $0.fit = next }
                             },
                             announcement: { state.fit.title })
    }

    @MainActor
    static func crop(_ state: ReaderState, onCrop: @escaping () -> Void) -> ReaderBarItem {
        let cropped = state.crop.map { !$0.isNone } ?? false
        return ReaderBarItem(id: "crop", group: .pages, label: cropped ? "Edit Page Crop" : "Crop Pages",
                             icon: AnyView(Image(systemName: "crop")),
                             behavior: .action(onCrop),
                             isOn: cropped)
    }

    @MainActor
    static func direction(_ state: ReaderState) -> ReaderBarItem {
        ReaderBarItem(id: "direction", group: .reading, label: "Reading Direction, \(state.direction.title)",
                      icon: AnyView(DirectionIcon(rightToLeft: state.rightToLeft)),
                      behavior: .action {
                          state.change { $0.direction = state.rightToLeft ? .leftToRight : .rightToLeft }
                      },
                      announcement: { state.direction.title })
    }

    @MainActor
    static func background(_ state: ReaderState) -> ReaderBarItem {
        ReaderBarItem(id: "background", group: .look, label: "Background, \(state.background.choice.title)",
                      icon: AnyView(BackgroundIcon(background: state.background)),
                      behavior: .panel { _ in AnyView(BackgroundPanel(state: state)) })
    }

    @MainActor
    static func adjustments(_ state: ReaderState) -> ReaderBarItem {
        let changed = !state.look.isNone
        return ReaderBarItem(id: "adjust", group: .look, label: changed ? "Image Adjustments, on" : "Image Adjustments",
                             icon: AnyView(AdjustmentsIcon()),
                             behavior: .panel { _ in AnyView(AdjustmentsPanel(state: state)) },
                             isOn: changed)
    }

    @MainActor
    static func more(_ state: ReaderState) -> ReaderBarItem {
        ReaderBarItem(id: "more", group: .more, label: "More Settings",
                      icon: AnyView(Image(systemName: "ellipsis")),
                      behavior: .panel { _ in AnyView(MoreSettingsPanel(state: state)) })
    }
}

// MARK: - The bar

/// A glass capsule of icon buttons under the book's title.
struct ReaderMenuBar: View {
    let items: [ReaderBarItem]
    @State private var openPanel: String?
    @State private var announcement: String?
    @State private var announcementTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0, items[index - 1].group != item.group {
                    Capsule()
                        .fill(.secondary.opacity(0.45))
                        .frame(width: 1, height: 22)
                        .padding(.horizontal, 7)
                }
                cell(item)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: .capsule)
        // A container of its own, so its identifier doesn't replace each button's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-menu-bar")
        // The new value, faded in just under the bar. An overlay, so nothing moves, and not
        // glass: glass beside the bar's glass flows out of it instead of fading in.
        .overlay(alignment: .bottom) {
            if let announcement {
                Text(announcement)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: 46)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: announcement)
        .onDisappear { announcementTask?.cancel() }
    }

    @ViewBuilder
    private func cell(_ item: ReaderBarItem) -> some View {
        switch item.behavior {
        case .info:
            item.icon
                .frame(width: 40, height: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.label)
                .accessibilityIdentifier("reader-bar-\(item.id)")
        case .action(let action):
            Button {
                action()
                if let text = item.announcement { announce(text()) }
            } label: {
                item.icon
            }
            .buttonStyle(ReaderBarButtonStyle(isOn: item.isOn, tint: item.tint))
            .accessibilityLabel(item.label)
            .accessibilityIdentifier("reader-bar-\(item.id)")
        case .panel(let content):
            Button {
                openPanel = item.id
            } label: {
                item.icon
            }
            .buttonStyle(ReaderBarButtonStyle(isOn: item.isOn, isOpen: openPanel == item.id, tint: item.tint))
            .accessibilityLabel(item.label)
            .accessibilityIdentifier("reader-bar-\(item.id)")
            .popover(isPresented: Binding(
                get: { openPanel == item.id },
                set: { if !$0, openPanel == item.id { openPanel = nil } }
            ), arrowEdge: .top) {
                content { openPanel = nil }
                    // Popovers don't pick up the app root's switch style (#55).
                    .toggleStyle(MonoToggleStyle())
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func announce(_ text: String) {
        announcement = text
        announcementTask?.cancel()
        announcementTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            if Task.isCancelled { return }
            announcement = nil
        }
    }
}

/// An icon button in the bar: a soft highlight when its setting is on or its panel is open,
/// and a little give when pressed.
struct ReaderBarButtonStyle: ButtonStyle {
    var isOn = false
    var isOpen = false
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        // On, a tinted button (the pink heart, the orange bookmark) keeps its color on a soft
        // wash; any other is a solid primary circle with the icon in the inverse color (#55).
        let foreground: Color = isOn ? (tint ?? Color.onAccent) : Color.primary
        let fill: Color = isOn
            ? (tint.map { $0.opacity(0.2) } ?? Color.primary)
            : Color.primary.opacity(isOpen ? 0.14 : 0)
        configuration.label
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 40, height: 40)
            .background {
                Circle()
                    .fill(fill)
                    .padding(2)
            }
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isOn)
            .animation(.easeOut(duration: 0.18), value: isOpen)
    }
}
