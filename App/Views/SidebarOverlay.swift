import SwiftUI

/// The library sidebar as a floating panel over the library (#56). It slides in from the left
/// and follows the finger: drag right from the library's left edge to pull it out, drag it left
/// to put it away. The library behind dims as the panel comes out, and a tap on the dimmed
/// library closes it. The library never moves or resizes.
struct SidebarOverlay<Library: View, Sidebar: View>: View {
    @Binding var isShown: Bool
    /// False inside a folder or series, where the left-edge swipe belongs to Back.
    var edgeSwipeEnabled: Bool
    @ViewBuilder var library: Library
    @ViewBuilder var sidebar: Sidebar

    static var width: CGFloat { 300 }
    private static var edgeWidth: CGFloat { 22 }
    private static var maxDim: Double { 0.28 }

    /// How far the finger has moved the panel from where it rests, while dragging.
    @State private var drag: CGFloat?
    /// Whether the current drag on the panel is sideways (decided at its start), so vertical
    /// scrolling in the sidebar is left alone.
    @State private var dragIsSideways: Bool?

    private var travel: CGFloat { Self.width }

    /// 0 when hidden, 1 when fully out.
    private var progress: CGFloat {
        let base: CGFloat = isShown ? travel : 0
        return min(max((base + (drag ?? 0)) / travel, 0), 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            library

            // Dim the library as the panel comes out; a tap on it closes the panel.
            Color.black
                .opacity(Self.maxDim * progress)
                .ignoresSafeArea()
                .allowsHitTesting(progress > 0)
                .onTapGesture { setShown(false) }
                .gesture(closeGesture)
                .accessibilityHidden(true)

            // Kept in place while hidden (off screen), so it slides out as well as in.
            panel
                .offset(x: -(travel + 30) * (1 - progress))
                .allowsHitTesting(progress > 0)
                .accessibilityHidden(progress == 0)

            if !isShown, edgeSwipeEnabled {
                Color.clear
                    .frame(width: Self.edgeWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(openGesture)
                    // Below the toolbar, so the sidebar button's taps get through.
                    .padding(.top, 80)
                    .accessibilityHidden(true)
            }
        }
    }

    private var panel: some View {
        // A full-height frosted sheet along the left edge, like a system slide-over sidebar.
        sidebar
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .background(.thinMaterial, ignoresSafeAreaEdges: .all)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5).ignoresSafeArea()
            }
            .shadow(color: .black.opacity(0.15 * progress), radius: 12, x: 2)
            .simultaneousGesture(closeGesture)
    }

    /// From the left edge: the panel follows the finger out.
    private var openGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                drag = max(0, value.translation.width)
            }
            .onEnded { value in
                let opened = value.predictedEndTranslation.width > travel / 2
                finish(shown: opened)
            }
    }

    /// On the panel or the dimmed library: a sideways drag left pushes the panel away.
    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard isShown else { return }
                if dragIsSideways == nil {
                    dragIsSideways = abs(value.translation.width) > abs(value.translation.height)
                }
                guard dragIsSideways == true else { return }
                drag = min(0, value.translation.width)
            }
            .onEnded { value in
                defer { dragIsSideways = nil }
                guard isShown, dragIsSideways == true else { return }
                let closed = value.predictedEndTranslation.width < -travel / 2
                finish(shown: !closed)
            }
    }

    private func finish(shown: Bool) {
        withAnimation(.snappy(duration: 0.28)) {
            isShown = shown
            drag = nil
        }
    }

    private func setShown(_ shown: Bool) {
        guard isShown != shown else { return }
        finish(shown: shown)
    }
}

/// Opens and closes the sidebar from anywhere below the root view (the toolbar button).
struct SidebarToggleAction {
    var toggle: () -> Void = {}
    var close: () -> Void = {}
}

extension EnvironmentValues {
    @Entry var sidebarToggle = SidebarToggleAction()
}

/// The toolbar button that opens or closes the sidebar.
struct SidebarButton: ToolbarContent {
    @Environment(\.sidebarToggle) private var sidebarToggle

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Sidebar", systemImage: "sidebar.left") { sidebarToggle.toggle() }
                .accessibilityIdentifier("sidebar-toggle")
        }
    }
}
