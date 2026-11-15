import SwiftUI

/// The kinds of library grid that remember Show Titles separately (issue #57), so each can
/// have its own default.
enum TitleGrid {
    case books, series, folders

    var key: String {
        switch self {
        case .books: return "library.showTitles.books"
        case .series: return "library.showTitles.series"
        case .folders: return "library.showTitles.folders"
        }
    }
}

extension EnvironmentValues {
    /// Whether library cells show the title under the cover. Set by each grid from its own setting.
    @Entry var showTitles = true
}

/// A thin line between two parts of a page, fading out towards its ends.
struct SoftDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .primary.opacity(0), location: 0),
                .init(color: .primary.opacity(0.22), location: 0.2),
                .init(color: .primary.opacity(0.22), location: 0.8),
                .init(color: .primary.opacity(0), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: max(1 / displayScale, 0.5))
        .accessibilityHidden(true)
    }
}

/// The back cards of a series stack (issue #59): drawn behind a cover, the same shape, each
/// one narrower and peeking a fixed amount above the top, so the stack shows at every cover
/// size and every stack in a row keeps the same bottom edge.
struct StackCards: View {
    @Environment(\.coverStyle) private var style
    /// How many cards to draw behind the cover (0, 1 or 2).
    let count: Int

    /// The space above the cover that the cards peek into. Every stack cell reserves it,
    /// with or without cards, so all covers in a row line up.
    static let peek: CGFloat = 12

    var body: some View {
        ZStack {
            if count >= 2 { card(level: 2, fill: Color(.systemGray4)) }
            if count >= 1 { card(level: 1, fill: Color(.systemGray3)) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func card(level: Int, fill: Color) -> some View {
        let step = Self.peek / 2
        return RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            .fill(fill)
            .padding(.horizontal, step * 1.5 * CGFloat(level))
            .offset(y: -step * CGFloat(level))
    }
}
