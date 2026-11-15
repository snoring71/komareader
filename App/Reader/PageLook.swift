import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// How the reader draws pages: contrast, sharpness and a printed-paper look. Every value at
/// 0 leaves the page as it is.
struct PageLook: Equatable, Sendable {
    /// -1 (flatter) to 1 (punchier).
    var contrast: Double = 0
    /// 0 to 1.
    var sharpness: Double = 0
    /// A paper texture over the page, 0 to 1.
    var paperGrain: Double = 0
    /// A warm paper colour, 0 to 1.
    var paperTint: Double = 0

    /// The part that is baked into the page image (the grain is drawn over it instead).
    var adjustments: PageAdjustments {
        PageAdjustments(contrast: contrast, sharpness: sharpness, tint: paperTint)
    }

    var isNone: Bool { adjustments.isNone && paperGrain < 0.005 }
}

/// The filters applied to a decoded page image.
struct PageAdjustments: Hashable, Sendable {
    var contrast: Double
    var sharpness: Double
    var tint: Double

    var isNone: Bool { abs(contrast) < 0.005 && sharpness < 0.005 && tint < 0.005 }

    /// Identifies the result in the page cache (to two decimals, as the sliders step).
    var key: String { String(format: "%.2f|%.2f|%.2f", contrast, sharpness, tint) }
}

/// Applies `PageAdjustments` with Core Image, on the GPU.
enum PageFilter {
    /// One context for the app: making one is expensive, and it is safe to share between threads.
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func apply(_ adjustments: PageAdjustments, to image: CGImage) -> CGImage? {
        guard !adjustments.isNone else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var output = input
        if abs(adjustments.contrast) >= 0.005 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            // 0.6× to 1.6×: the low end softens harsh scans, the high end deepens faded blacks.
            filter.contrast = Float(1 + adjustments.contrast * (adjustments.contrast < 0 ? 0.4 : 0.6))
            filter.saturation = 1
            filter.brightness = 0
            if let result = filter.outputImage { output = result }
        }
        if adjustments.sharpness >= 0.005 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = output
            filter.sharpness = Float(adjustments.sharpness * 1.5)
            filter.radius = 1.6
            if let result = filter.outputImage { output = result }
        }
        if adjustments.tint >= 0.005 {
            // Multiplies the page by a warm cream: white paper yellows, black ink stays black.
            let t = CGFloat(adjustments.tint)
            let filter = CIFilter.colorMatrix()
            filter.inputImage = output
            filter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: 1 - 0.07 * t, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: 1 - 0.3 * t, w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            if let result = filter.outputImage { output = result }
        }
        return context.createCGImage(output.cropped(to: extent), from: extent)
    }

    /// The average colour of an image (for the cover intro's background).
    static func averageColor(of image: CGImage) -> UIColor? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }
}

/// A tile of paper texture: fine speckle over soft blotches, as light and dark specks with
/// transparency, so it can lie over any page. Made once, then repeated across the page.
enum PaperGrain {
    @MainActor static let pattern: UIColor = UIColor(patternImage: makeTile())

    private static func makeTile() -> UIImage {
        let size = 192
        var generator = SplitMix(seed: 0x5EED_C0FFEE)
        // Soft blotches: coarse noise, smoothly enlarged.
        let coarse = 12
        let blotches = (0..<(coarse * coarse)).map { _ in generator.nextUnit() * 2 - 1 }
        func blotch(_ x: Int, _ y: Int) -> Double {
            let fx = Double(x) / Double(size) * Double(coarse), fy = Double(y) / Double(size) * Double(coarse)
            let x0 = Int(fx) % coarse, y0 = Int(fy) % coarse
            let x1 = (x0 + 1) % coarse, y1 = (y0 + 1) % coarse
            let tx = fx - floor(fx), ty = fy - floor(fy)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let top = blotches[y0 * coarse + x0] * (1 - sx) + blotches[y0 * coarse + x1] * sx
            let bottom = blotches[y1 * coarse + x0] * (1 - sx) + blotches[y1 * coarse + x1] * sx
            return top * (1 - sy) + bottom * sy
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                // Fine grain, a little stronger in the darker blotches, like paper fibres.
                let fine = (generator.nextUnit() + generator.nextUnit() + generator.nextUnit()) / 3 * 2 - 1
                let value = fine * 0.75 + blotch(x, y) * 0.35
                let alpha = min(1, abs(value) * 0.55)
                let shade: UInt8 = value < 0 ? 0 : 255
                let i = (y * size + x) * 4
                // Premultiplied: a white speck's colour is its alpha.
                let a = UInt8(alpha * 255)
                let c = shade == 0 ? 0 : a
                pixels[i] = c
                pixels[i + 1] = c
                pixels[i + 2] = c
                pixels[i + 3] = a
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        // One texture pixel per screen pixel, so the grain stays fine.
        return image.map { UIImage(cgImage: $0, scale: 2, orientation: .up) } ?? UIImage()
    }

    /// A small, repeatable random generator, so the paper looks the same every launch.
    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
