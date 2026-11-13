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

/// A drop shadow behind a cover. It is drawn once per strength into a small stretchable image,
/// so scrolling a grid of covers costs one plain image draw per cover, with no blur or
/// offscreen pass per frame the way `.shadow()` on every cell would.
struct CoverShadow: View {
    let strength: Double
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if strength > 0.001 {
            let shadow = CoverShadowImage.image(strength: strength, scale: displayScale)
            Image(uiImage: shadow.image)
                .resizable(capInsets: EdgeInsets(top: shadow.cap, leading: shadow.cap, bottom: shadow.cap, trailing: shadow.cap),
                           resizingMode: .stretch)
                .padding(-shadow.padding)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@MainActor
enum CoverShadowImage {
    struct Rendered {
        let image: UIImage
        /// How far the image reaches past the cover on each side, in points.
        let padding: CGFloat
        /// Edge that must not be stretched, in points.
        let cap: CGFloat
    }

    private struct Key: Hashable { let step: Int; let scale: CGFloat }
    private static var cache: [Key: Rendered] = [:]

    /// The look for a strength from 0 to 1: blur, how far down it falls, and how dark it is.
    static func metrics(strength: Double) -> (blur: CGFloat, offsetY: CGFloat, opacity: CGFloat) {
        let s = CGFloat(min(max(strength, 0), 1))
        return (blur: 3 + 14 * s, offsetY: 1 + 5 * s, opacity: 0.12 + 0.5 * s)
    }

    static func image(strength: Double, scale: CGFloat) -> Rendered {
        // Twenty steps are plenty, and dragging the slider then only ever makes twenty images.
        let step = Int((min(max(strength, 0), 1) * 20).rounded())
        let key = Key(step: step, scale: scale)
        if let cached = cache[key] { return cached }
        let rendered = render(strength: Double(step) / 20, scale: max(scale, 1))
        cache[key] = rendered
        return rendered
    }

    private static func render(strength: Double, scale: CGFloat) -> Rendered {
        let (blur, offsetY, opacity) = metrics(strength: strength)
        let corner = CoverStyle.cornerRadius
        let padding = ceil(blur + offsetY + 1)
        let cap = padding + corner + offsetY + 1
        let side = cap * 2 + 2 // the middle 2 points are what stretches

        // Drawn in pixels at scale 1: Core Graphics applies shadow offset and blur in device
        // space, not through the transform, so this keeps them predictable.
        let pixels = side * scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { context in
            let cg = context.cgContext
            let cover = CGRect(x: padding, y: padding, width: side - 2 * padding, height: side - 2 * padding)
            let scaled = { (rect: CGRect) in CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale) }
            // The shape is drawn far off to the left and only its shadow is moved onto the image,
            // sideways so the flipped y axis cannot turn the shadow upwards.
            let away = pixels * 2
            let caster = scaled(cover.offsetBy(dx: 0, dy: offsetY)).offsetBy(dx: -away, dy: 0)
            cg.setShadow(offset: CGSize(width: away, height: 0), blur: blur * scale,
                         color: UIColor.black.withAlphaComponent(opacity).cgColor)
            cg.addPath(UIBezierPath(roundedRect: caster, cornerRadius: corner * scale).cgPath)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fillPath()
            // Nothing under the cover itself, so a see-through placeholder does not turn grey.
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setBlendMode(.clear)
            cg.addPath(UIBezierPath(roundedRect: scaled(cover), cornerRadius: corner * scale).cgPath)
            cg.fillPath()
        }
        guard let cgImage = image.cgImage else { return Rendered(image: image, padding: padding, cap: cap) }
        return Rendered(image: UIImage(cgImage: cgImage, scale: scale, orientation: .up), padding: padding, cap: cap)
    }
}

/// UserDefaults keys for settings read in more than one view.
enum SettingsKeys {
    static let coverShape = "library.coverShape"
    static let coverShadow = "library.coverShadow"
}
