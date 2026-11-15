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

    /// Everything is baked into the page image when it is decoded.
    var adjustments: PageAdjustments {
        PageAdjustments(contrast: contrast, sharpness: sharpness, tint: paperTint, grain: paperGrain)
    }

    var isNone: Bool { adjustments.isNone }
}

/// The filters applied to a decoded page image.
struct PageAdjustments: Hashable, Sendable {
    var contrast: Double
    var sharpness: Double
    var tint: Double
    var grain: Double

    var isNone: Bool { abs(contrast) < 0.005 && sharpness < 0.005 && tint < 0.005 && grain < 0.005 }

    /// Identifies the result in the page cache (to two decimals, as the sliders step).
    var key: String { String(format: "%.2f|%.2f|%.2f|%.2f", contrast, sharpness, tint, grain) }
}

/// Applies `PageAdjustments` with Core Image, on the GPU.
enum PageFilter {
    /// One context for the app: making one is expensive, and it is safe to share between threads.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// `seed` (the page number) gives each page its own sheet of paper.
    static func apply(_ adjustments: PageAdjustments, to image: CGImage, seed: Int = 0) -> CGImage? {
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
        if adjustments.grain >= 0.005 {
            output = PaperGrain.apply(to: output, amount: adjustments.grain, seed: seed)
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

/// Printed paper, made fresh for each page with Core Image noise, so it never repeats:
/// fine speckle from the paper's fibres, a softer mottle where the ink took unevenly, and a
/// broad, faint unevenness of tone. Each layer only darkens (it multiplies the page), so
/// white paper turns a little grey and uneven, as in a scan, and black ink stays black.
enum PaperGrain {
    static func apply(to page: CIImage, amount: Double, seed: Int) -> CIImage {
        let extent = page.extent
        // Sizes are set for a page about as tall as the screen, and scale with the image.
        let unit = max(extent.width, extent.height) / 2400
        // Each page starts from a different place in the noise.
        let shift = CGAffineTransform(translationX: CGFloat((seed * 7919) % 5003) * 7, y: CGFloat((seed * 104_729) % 4001) * 5)
        let a = CGFloat(min(max(amount, 0), 1))
        let layers: [(scale: CGFloat, blur: Double, gain: CGFloat, strength: CGFloat)] = [
            (1, 0.55, 1.6, 0.22),     // fibres: single-pixel speckle, slightly softened
            (3.5, 1.6, 2.4, 0.18),    // mottle
            (90, 60, 3.0, 0.10),      // broad unevenness of tone
        ]
        var output = page
        for (index, layer) in layers.enumerated() {
            guard let random = CIFilter.randomGenerator().outputImage else { continue }
            let scale = max(1, layer.scale * unit)
            let noise = random
                .transformed(by: shift.translatedBy(x: CGFloat(index) * 1013, y: CGFloat(index) * 727))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .applyingGaussianBlur(sigma: layer.blur * Double(unit))
            // Grey from the red channel: v = 0.5 + gain (x − 0.5), then the multiplier
            // m = 1 − k v, with k the layer's strength at this amount.
            let k = layer.strength * a
            let g = layer.gain
            let weight = -k * g
            let bias = 1 - k * 0.5 * (1 - g)
            let multiplier = CIFilter.colorMatrix()
            multiplier.inputImage = noise
            multiplier.rVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            multiplier.gVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            multiplier.bVector = CIVector(x: weight, y: 0, z: 0, w: 0)
            multiplier.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            multiplier.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
            guard let sheet = multiplier.outputImage else { continue }
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = sheet
            clamp.minComponents = CIVector(x: 1 - k, y: 1 - k, z: 1 - k, w: 1)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            guard let clamped = clamp.outputImage?.cropped(to: extent) else { continue }
            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = clamped
            multiply.backgroundImage = output
            if let result = multiply.outputImage { output = result.cropped(to: extent) }
        }
        return output
    }
}
