import SwiftUI
import UIKit

/// How covers look in the library: their proportions and how strong their drop shadow is.
/// Set once near the root from Settings, so a grid cell does not watch UserDefaults itself.
struct CoverStyle: Equatable {
    var shape: CoverShape = .comic
    /// 0 is no shadow, 1 the strongest.
    var shadowStrength: Double = CoverStyle.defaultShadowStrength
    var shadowDirection: CoverShadowDirection = .around

    static let defaultShadowStrength = 0.35
    static let cornerRadius: CGFloat = 6
}

extension EnvironmentValues {
    @Entry var coverStyle = CoverStyle()
}

/// The proportions of a cover in the library grid and of the locked crops in the cover editor.
enum CoverShape: String, CaseIterable, Identifiable {
    /// US comics are about 6.6 × 10.2 inches; 2:3 is the usual rounding.
    case comic
    /// Japanese B6 tankōbon, 128 × 182 mm: a little wider than 2:3, and close to most digital manga.
    case manga

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comic: return "Comic 2:3"
        case .manga: return "Manga B6"
        }
    }

    /// Width divided by height.
    var aspect: CGFloat {
        switch self {
        case .comic: return 2.0 / 3.0
        case .manga: return 128.0 / 182.0
        }
    }
}

/// Where a cover's shadow falls.
enum CoverShadowDirection: String, CaseIterable, Identifiable {
    /// A soft glow on every side, a little lower than the cover.
    case around
    /// Cast down onto the shelf, as if lit from the front and above: dark under the bottom
    /// edge, faint at the sides, none at the top.
    case below
    case belowRight
    case belowLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .around: return "All Around"
        case .below: return "Below"
        case .belowRight: return "Below Right"
        case .belowLeft: return "Below Left"
        }
    }
}

/// A drop shadow behind a cover, drawn by Core Animation from an outline. With the outline
/// given (`shadowPath`), the shadow needs no offscreen pass to work out the shape from the
/// cover's pixels, which is what makes `.shadow()` on every grid cell expensive.
struct CoverShadow: View {
    let strength: Double
    var direction: CoverShadowDirection = .around

    var body: some View {
        if strength > 0.001 {
            CoverShadowLayer(look: Look(strength: strength, direction: direction))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Everything the layer needs, worked out from the two settings.
    struct Look: Equatable {
        var radius: CGFloat
        var opacity: Float
        var offset: CGSize
        /// How far the outline is pulled in at the sides and reaches past the bottom, in points.
        var sideInset: CGFloat
        var bottomReach: CGFloat
        /// The outline's top, as a fraction of the cover's height (the cover hides what is above).
        var topFraction: CGFloat

        init(strength: Double, direction: CoverShadowDirection) {
            let s = CGFloat(min(max(strength, 0), 1))
            switch direction {
            case .around:
                radius = 2 + 7 * s
                opacity = Float(0.12 + 0.5 * s)
                offset = CGSize(width: 0, height: 1 + 5 * s)
                sideInset = 0
                bottomReach = 0
                topFraction = 0
            case .below, .belowRight, .belowLeft:
                // A narrower outline that reaches below the cover: a dark band under the bottom
                // edge fading down, with only a trace at the sides.
                radius = 2 + 5 * s
                opacity = Float(0.25 + 0.6 * s)
                let side: CGFloat = direction == .belowRight ? 1 : direction == .belowLeft ? -1 : 0
                offset = CGSize(width: side * (1 + 4 * s), height: 0)
                sideInset = side == 0 ? 2 : 0
                bottomReach = 1 + 5 * s
                topFraction = 0.5
            }
        }

        func path(in bounds: CGRect) -> CGPath {
            var rect = bounds.insetBy(dx: sideInset, dy: 0)
            rect.origin.y += bounds.height * topFraction
            rect.size.height = bounds.maxY + bottomReach - rect.minY
            return UIBezierPath(roundedRect: rect, cornerRadius: CoverStyle.cornerRadius).cgPath
        }
    }
}

private struct CoverShadowLayer: UIViewRepresentable {
    let look: CoverShadow.Look

    func makeUIView(context: Context) -> ShadowView {
        let view = ShadowView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ view: ShadowView, context: Context) {
        view.look = look
    }

    final class ShadowView: UIView {
        var look: CoverShadow.Look? {
            didSet {
                guard let look, look != oldValue else { return }
                layer.shadowRadius = look.radius
                layer.shadowOffset = look.offset
                layer.shadowOpacity = look.opacity
                pathBounds = .null
                setNeedsLayout()
            }
        }

        private var pathBounds = CGRect.null

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let look, bounds != pathBounds else { return }
            pathBounds = bounds
            layer.shadowPath = look.path(in: bounds)
        }
    }
}

/// UserDefaults keys for settings read in more than one view.
enum SettingsKeys {
    static let coverShape = "library.coverShape"
    static let coverShadow = "library.coverShadow"
    static let coverShadowDirection = "library.coverShadowDirection"
}
