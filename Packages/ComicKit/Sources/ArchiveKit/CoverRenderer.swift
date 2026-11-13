import CoreGraphics
import Foundation

/// Turns a cover recipe (rotation, then crop) into an image. The same steps are documented in
/// SCHEMA.md so other apps can re-render a cover from the recipe.
public enum CoverRenderer {
    /// Rotates `image` clockwise by `degrees` (0, 90, 180 or 270).
    public static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let turns = ((degrees / 90) % 4 + 4) % 4
        guard turns != 0 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Core Graphics has y pointing up, so a clockwise turn on screen is these transforms.
        let transform: CGAffineTransform
        switch turns {
        case 1: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        default: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        context.concatenate(transform)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// Crops to `crop` = [x, y, width, height] as fractions of the image, measured from the top left.
    public static func crop(_ image: CGImage, to crop: [Double]) -> CGImage? {
        guard crop.count == 4 else { return image }
        let w = Double(image.width), h = Double(image.height)
        let x = min(max(crop[0], 0), 1), y = min(max(crop[1], 0), 1)
        let width = min(max(crop[2], 0), 1 - x), height = min(max(crop[3], 0), 1 - y)
        if x == 0, y == 0, width >= 1, height >= 1 { return image }
        let rect = CGRect(x: x * w, y: y * h, width: max(1, width * w), height: max(1, height * h)).integral
        return image.cropping(to: rect)
    }

    /// Applies a whole recipe: rotate first, then crop.
    public static func render(_ image: CGImage, crop cropRect: [Double], rotation: Int) -> CGImage? {
        guard let rotated = rotate(image, degrees: rotation) else { return nil }
        return crop(rotated, to: cropRect)
    }
}
