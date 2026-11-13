import SwiftUI
import UIKit

/// How covers look in the library: their proportions and how strong their drop shadow is.
/// Set once near the root from Settings, so a grid cell does not watch UserDefaults itself.
struct CoverStyle: Equatable {
    var shape: CoverShape = .comic
    /// 0 is no shadow, 1 the strongest.
    var shadowStrength: Double = CoverStyle.defaultShadowStrength

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

/// A drop shadow behind a cover, drawn by Core Animation from the cover's outline. With the
/// outline given (`shadowPath`), the shadow needs no offscreen pass to work out the shape
/// from the cover's pixels, which is what makes `.shadow()` on every grid cell expensive.
struct CoverShadow: View {
    let strength: Double

    var body: some View {
        if strength > 0.001 {
            CoverShadowLayer(strength: strength)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The look for a strength from 0 to 1: blur radius, how far down it falls, and how dark it is.
    static func metrics(strength: Double) -> (radius: CGFloat, offsetY: CGFloat, opacity: Float) {
        let s = min(max(strength, 0), 1)
        return (radius: 2 + 7 * CGFloat(s), offsetY: 1 + 5 * CGFloat(s), opacity: Float(0.12 + 0.5 * s))
    }
}

private struct CoverShadowLayer: UIViewRepresentable {
    let strength: Double

    func makeUIView(context: Context) -> ShadowView {
        let view = ShadowView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.shadowColor = UIColor.black.cgColor
        return view
    }

    func updateUIView(_ view: ShadowView, context: Context) {
        view.strength = strength
    }

    final class ShadowView: UIView {
        var strength: Double = -1 {
            didSet {
                guard strength != oldValue else { return }
                let metrics = CoverShadow.metrics(strength: strength)
                layer.shadowRadius = metrics.radius
                layer.shadowOffset = CGSize(width: 0, height: metrics.offsetY)
                layer.shadowOpacity = metrics.opacity
            }
        }

        private var pathBounds = CGRect.null

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds != pathBounds else { return }
            pathBounds = bounds
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: CoverStyle.cornerRadius).cgPath
        }
    }
}

/// UserDefaults keys for settings read in more than one view.
enum SettingsKeys {
    static let coverShape = "library.coverShape"
    static let coverShadow = "library.coverShadow"
}
