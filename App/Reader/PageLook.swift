import ComicCore
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// How the reader draws pages: levels, colour, sharpness, night modes and a printed-paper
/// look. Every value at its default leaves the page as it is.
struct PageLook: Equatable, Sendable {
    typealias NightMode = BookRecord.ReaderOptions.NightMode
    typealias PaperStock = BookRecord.ReaderOptions.PaperStock

    /// -1 (flatter) to 1 (punchier).
    var contrast: Double = 0
    /// 0 to 1.
    var sharpness: Double = 0
    /// A paper texture over the page, 0 to 1.
    var paperGrain: Double = 0
    /// A warm paper colour, 0 to 1.
    var paperTint: Double = 0
    /// -1 (darker) to 1 (lighter).
    var brightness: Double = 0
    /// Midtones, -1 (darker) to 1 (lighter).
    var gamma: Double = 0
    /// -1 (grey) to 1 (stronger colour).
    var saturation: Double = 0
    var blackAndWhite = false
    /// White point, black point and tint worked out from each page (#115).
    var autoFix = false
    var nightMode: NightMode = .off
    var nightOnlyInDark = false
    /// Halftone and JPEG smoothing, 0 to 1 (#119).
    var descreen: Double = 0
    /// Lanczos resizing to the size on screen (#120). Applied when a page is shown, not baked in.
    var sharperScaling = false
    /// Colour pages keep their colour under a black-and-white fix (#122).
    var keepColorPages = true
    var paperStock: PaperStock = .plain
    /// Whether the system appearance is dark now, for `nightOnlyInDark`. Not saved.
    var darkAppearance = false

    /// The night mode in effect now.
    var activeNightMode: NightMode {
        nightOnlyInDark && !darkAppearance ? .off : nightMode
    }

    /// Everything that is baked into the page image when it is decoded.
    var adjustments: PageAdjustments {
        PageAdjustments(contrast: contrast, sharpness: sharpness, tint: paperTint, grain: paperGrain,
                        brightness: brightness, gamma: gamma, saturation: saturation, mono: blackAndWhite,
                        autoFix: autoFix, night: activeNightMode, descreen: descreen,
                        keepColor: keepColorPages, stock: paperStock)
    }

    var isNone: Bool { adjustments.isNone && !sharperScaling }

    /// The look as a book's saved settings (every value, set or not), for named looks.
    var options: ReaderOptions {
        var options = ReaderOptions(updatedAt: .distantPast)
        options.contrast = contrast
        options.sharpness = sharpness
        options.paperGrain = paperGrain
        options.paperTint = paperTint
        options.brightness = brightness
        options.gamma = gamma
        options.saturation = saturation
        options.blackAndWhite = blackAndWhite
        options.autoFix = autoFix
        options.nightMode = nightMode
        options.nightOnlyInDark = nightOnlyInDark
        options.descreen = descreen
        options.sharperScaling = sharperScaling
        options.keepColorPages = keepColorPages
        options.paperStock = paperStock
        return options
    }

    /// The look `options` sets, falling back on `base` for anything it leaves out.
    init(options: ReaderOptions, base: PageLook) {
        contrast = options.contrast ?? base.contrast
        sharpness = options.sharpness ?? base.sharpness
        paperGrain = options.paperGrain ?? base.paperGrain
        paperTint = options.paperTint ?? base.paperTint
        brightness = options.brightness ?? base.brightness
        gamma = options.gamma ?? base.gamma
        saturation = options.saturation ?? base.saturation
        blackAndWhite = options.blackAndWhite ?? base.blackAndWhite
        autoFix = options.autoFix ?? base.autoFix
        nightMode = options.nightMode ?? base.nightMode
        nightOnlyInDark = options.nightOnlyInDark ?? base.nightOnlyInDark
        descreen = options.descreen ?? base.descreen
        sharperScaling = options.sharperScaling ?? base.sharperScaling
        keepColorPages = options.keepColorPages ?? base.keepColorPages
        paperStock = options.paperStock ?? base.paperStock
        darkAppearance = base.darkAppearance
    }

    init() {}

    /// Writes into `options` the values that differ from `saved`.
    func write(changesFrom saved: PageLook, into options: inout ReaderOptions) {
        if contrast != saved.contrast { options.contrast = contrast }
        if sharpness != saved.sharpness { options.sharpness = sharpness }
        if paperGrain != saved.paperGrain { options.paperGrain = paperGrain }
        if paperTint != saved.paperTint { options.paperTint = paperTint }
        if brightness != saved.brightness { options.brightness = brightness }
        if gamma != saved.gamma { options.gamma = gamma }
        if saturation != saved.saturation { options.saturation = saturation }
        if blackAndWhite != saved.blackAndWhite { options.blackAndWhite = blackAndWhite }
        if autoFix != saved.autoFix { options.autoFix = autoFix }
        if nightMode != saved.nightMode { options.nightMode = nightMode }
        if nightOnlyInDark != saved.nightOnlyInDark { options.nightOnlyInDark = nightOnlyInDark }
        if descreen != saved.descreen { options.descreen = descreen }
        if sharperScaling != saved.sharperScaling { options.sharperScaling = sharperScaling }
        if keepColorPages != saved.keepColorPages { options.keepColorPages = keepColorPages }
        if paperStock != saved.paperStock { options.paperStock = paperStock }
    }

    /// Clears every image setting from `options`, so the book follows the defaults for them.
    static func clear(_ options: inout ReaderOptions) {
        options.contrast = nil
        options.sharpness = nil
        options.paperGrain = nil
        options.paperTint = nil
        options.brightness = nil
        options.gamma = nil
        options.saturation = nil
        options.blackAndWhite = nil
        options.autoFix = nil
        options.nightMode = nil
        options.nightOnlyInDark = nil
        options.descreen = nil
        options.sharperScaling = nil
        options.keepColorPages = nil
        options.paperStock = nil
    }
}

/// The filters applied to a decoded page image.
struct PageAdjustments: Hashable, Sendable {
    var contrast: Double
    var sharpness: Double
    var tint: Double
    var grain: Double
    var brightness: Double = 0
    var gamma: Double = 0
    var saturation: Double = 0
    var mono = false
    var autoFix = false
    var night: PageLook.NightMode = .off
    var descreen: Double = 0
    var keepColor = true
    var stock: PageLook.PaperStock = .plain

    var isNone: Bool {
        abs(contrast) < 0.005 && sharpness < 0.005 && tint < 0.005 && grain < 0.005
            && abs(brightness) < 0.005 && abs(gamma) < 0.005 && abs(saturation) < 0.005
            && !mono && !autoFix && night == .off && descreen < 0.005
    }

    /// A fix that drains colour, which colour pages are spared when `keepColor` is on.
    var drainsColor: Bool { mono || autoFix || night == .sepia }

    /// Identifies the result in the page cache (to two decimals, as the sliders step).
    var key: String {
        String(format: "%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.2f", contrast, sharpness, tint, grain, brightness, gamma, saturation, descreen)
            + "|\(mono ? 1 : 0)\(autoFix ? 1 : 0)\(keepColor ? 1 : 0)|\(night.rawValue)|\(stock.rawValue)"
    }
}

/// What a quick look at a page finds: its paper colour, how dark its ink is, and whether it
/// is a colour page.
struct PageStats: Equatable, Sendable {
    /// The paper's colour, sRGB 0 to 1.
    var paper: (red: Double, green: Double, blue: Double)
    /// The darkest ink, as sRGB lightness 0 to 1.
    var black: Double
    var isColor: Bool

    static func == (a: PageStats, b: PageStats) -> Bool {
        a.paper == b.paper && a.black == b.black && a.isColor == b.isColor
    }

    /// Measures a page from a small copy (about 160 pixels on its long side).
    static func measure(_ image: CIImage, context: CIContext) -> PageStats? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, 160 / max(extent.width, extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(1, Int((extent.width * scale).rounded(.down)))
        let height = max(1, Int((extent.height * scale).rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return measure(rgba: pixels, count: width * height)
    }

    /// The measurement itself, over RGBA8 pixels.
    static func measure(rgba pixels: [UInt8], count: Int) -> PageStats? {
        guard count > 0 else { return nil }
        var lightness = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let r = Double(pixels[i * 4]), g = Double(pixels[i * 4 + 1]), b = Double(pixels[i * 4 + 2])
            lightness[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        }
        let sorted = lightness.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(count - 1, max(0, Int(Double(count - 1) * p)))] }
        let white = percentile(0.97)
        let black = percentile(0.02)
        // The paper: the average of the brightest pixels.
        var sum = (r: 0.0, g: 0.0, b: 0.0), n = 0.0
        for i in 0..<count where lightness[i] >= white * 0.97 {
            sum.r += Double(pixels[i * 4]); sum.g += Double(pixels[i * 4 + 1]); sum.b += Double(pixels[i * 4 + 2])
            n += 1
        }
        let paper = n > 0 ? (red: sum.r / n / 255, green: sum.g / n / 255, blue: sum.b / n / 255) : (red: 1.0, green: 1.0, blue: 1.0)
        // Colour: pixels well away from grey once the paper's cast is taken out, ignoring
        // near-white and near-black ones, where scans are noisiest.
        var colourful = 0
        for i in 0..<count where lightness[i] > 0.12 && lightness[i] < 0.92 {
            let r = Double(pixels[i * 4]) / 255 / max(paper.red, 0.3)
            let g = Double(pixels[i * 4 + 1]) / 255 / max(paper.green, 0.3)
            let b = Double(pixels[i * 4 + 2]) / 255 / max(paper.blue, 0.3)
            if max(r, g, b) - min(r, g, b) > 0.16 { colourful += 1 }
        }
        return PageStats(paper: paper, black: black, isColor: Double(colourful) / Double(count) > 0.04)
    }
}

/// Applies `PageAdjustments` with Core Image, on the GPU.
enum PageFilter {
    /// One context for the app: making one is expensive, and it is safe to share between threads.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// sRGB to linear light, which Core Image works in.
    private static func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// `seed` (the page number) gives each page its own sheet of paper.
    static func apply(_ adjustments: PageAdjustments, to image: CGImage, seed: Int = 0) -> CGImage? {
        guard !adjustments.isNone else { return nil }
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var output = input
        let unit = max(extent.width, extent.height) / 2400

        // A quick look at the page, when a fix depends on it.
        let needsStats = adjustments.autoFix || (adjustments.keepColor && adjustments.drainsColor)
        let stats = needsStats ? PageStats.measure(input, context: context) : nil
        let spareColor = adjustments.keepColor && stats?.isColor == true

        if adjustments.descreen >= 0.005 {
            output = descreen(output, amount: adjustments.descreen, unit: unit)
        }
        if adjustments.autoFix, let stats {
            output = autoLevels(output, stats: stats, keepTint: spareColor)
        }
        var contrast = adjustments.contrast, saturation = adjustments.saturation, brightness = adjustments.brightness
        if adjustments.stock == .glossy, adjustments.grain >= 0.005 {
            // Glossy paper: deeper blacks and richer colour.
            contrast += 0.12 * adjustments.grain
            saturation += 0.15 * adjustments.grain
        }
        let mono = adjustments.mono && !spareColor
        if abs(contrast) >= 0.005 || abs(saturation) >= 0.005 || abs(brightness) >= 0.005 || mono {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            // 0.6× to 1.6×: the low end softens harsh scans, the high end deepens faded blacks.
            filter.contrast = Float(1 + contrast * (contrast < 0 ? 0.4 : 0.6))
            filter.saturation = mono ? 0 : Float(max(0, 1 + saturation))
            filter.brightness = Float(brightness * 0.25)
            if let result = filter.outputImage { output = result }
        }
        if abs(adjustments.gamma) >= 0.005 {
            let filter = CIFilter.gammaAdjust()
            filter.inputImage = output
            // Lighter midtones for a positive value; black and white stay where they are.
            filter.power = Float(pow(2, -adjustments.gamma * 0.8))
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
            output = multiply(output, red: 1, green: 1 - 0.07 * t, blue: 1 - 0.3 * t)
        }
        if adjustments.grain >= 0.005 {
            output = PaperGrain.apply(to: output, amount: adjustments.grain, seed: seed, stock: adjustments.stock)
        }
        switch adjustments.night {
        case .off:
            break
        case .sepia:
            if !(adjustments.keepColor && spareColor) {
                let filter = CIFilter.sepiaTone()
                filter.inputImage = output
                filter.intensity = 0.9
                if let result = filter.outputImage { output = result }
            }
            output = multiply(output, red: 0.78, green: 0.78, blue: 0.78)
        case .dim:
            // White paper down to a soft grey (about 60% in sRGB); black ink stays black.
            output = multiply(output, red: 0.33, green: 0.33, blue: 0.33)
        case .invert:
            output = invertLightness(output)
        }
        return context.createCGImage(output.cropped(to: extent), from: extent)
    }

    /// Multiplies each channel (in linear light).
    private static func multiply(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat, bias: CGFloat = 0) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return filter.outputImage ?? image
    }

    /// Auto-fix (#115): the paper becomes white (its cast removed, unless `keepTint`) and
    /// the darkest ink black. Held back on pages where the measurement is unsure: a dark
    /// page keeps its white point, and the black point moves at most part of the way.
    static func autoLevels(_ image: CIImage, stats: PageStats, keepTint: Bool) -> CIImage {
        let paperLightness = 0.299 * stats.paper.red + 0.587 * stats.paper.green + 0.114 * stats.paper.blue
        // A mostly dark page (a black splash): no reliable paper to set white from.
        let usePaper = paperLightness >= 0.5
        var paper = usePaper ? stats.paper : (red: 1.0, green: 1.0, blue: 1.0)
        if keepTint { paper = (paperLightness, paperLightness, paperLightness) }
        if !usePaper { paper = (1, 1, 1) }
        // Never brighten a channel more than 1.6× (a page that is really that dark keeps some).
        let r = max(linear(paper.red), 0.62), g = max(linear(paper.green), 0.62), b = max(linear(paper.blue), 0.62)
        let blackPoint = min(linear(stats.black), linear(0.32))
        let range = max(1 - blackPoint, 0.5)
        let bias = CGFloat(-blackPoint / range)
        return multiply(image, red: CGFloat(1 / (r * range)), green: CGFloat(1 / (g * range)), blue: CGFloat(1 / (b * range)), bias: bias)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
    }

    /// Descreen (#119): blurs away halftone dots and JPEG blocks, then brings the line art's
    /// edges back, so lines stay crisp while flat areas smooth out.
    static func descreen(_ image: CIImage, amount: Double, unit: CGFloat) -> CIImage {
        let extent = image.extent
        let a = min(max(amount, 0), 1)
        let blurred = image.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(unit, 0.5)) * (0.5 + 1.3 * a))
            .cropped(to: extent)
        let noise = CIFilter.noiseReduction()
        noise.inputImage = blurred
        noise.noiseLevel = Float(0.01 + 0.03 * a)
        noise.sharpness = Float(0.6 + 0.8 * a)
        let smooth = noise.outputImage?.cropped(to: extent) ?? blurred
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = smooth
        sharpen.radius = Float(max(unit, 0.5) * 2.5)
        sharpen.intensity = Float(0.4 + 0.5 * a)
        return sharpen.outputImage?.cropped(to: extent) ?? smooth
    }

    /// Night mode Invert (#118): dark paper and light ink, with colours kept (the hue is
    /// turned back after inverting), worked in sRGB so midtones invert as the eye expects.
    static func invertLightness(_ image: CIImage) -> CIImage {
        let srgb = image.applyingFilter("CILinearToSRGBToneCurve")
        let inverted = srgb.applyingFilter("CIColorInvert")
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi])
        let back = inverted.applyingFilter("CISRGBToneCurveToLinear")
        // Not quite white ink, which glares in the dark.
        return multiply(back, red: 0.7, green: 0.7, blue: 0.7)
    }

    /// Lanczos resizing (#120) of a page to `size` pixels.
    static func lanczos(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard image.height > 0, size.width >= 1, size.height >= 1 else { return nil }
        let input = CIImage(cgImage: image)
        let scale = size.height / CGFloat(image.height)
        let filter = CIFilter.lanczosScaleTransform()
        // Clamped, so the filter has pixels to sample past the page's edges.
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = Float((size.width / CGFloat(image.width)) / scale)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: CGRect(x: 0, y: 0, width: size.width.rounded(), height: size.height.rounded()))
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
/// Each paper stock (#124) has its own layers and colour.
enum PaperGrain {
    typealias Layer = (scale: CGFloat, blur: Double, gain: CGFloat, strength: CGFloat)

    static func layers(for stock: PageLook.PaperStock) -> [Layer] {
        switch stock {
        case .plain:
            return [
                (1, 0.55, 1.6, 0.22),     // fibres: single-pixel speckle, slightly softened
                (3.5, 1.6, 2.4, 0.18),    // mottle
                (90, 60, 3.0, 0.10),      // broad unevenness of tone
            ]
        case .newsprint:
            // Coarse, cheap paper: heavier fibres and blotchy, uneven ink.
            return [
                (1.4, 0.7, 1.8, 0.28),
                (5, 2.4, 2.6, 0.24),
                (60, 40, 3.0, 0.14),
            ]
        case .cream:
            // Fine book paper: faint fibres, barely any mottle.
            return [
                (1, 0.5, 1.4, 0.10),
                (120, 80, 2.4, 0.05),
            ]
        case .glossy:
            // Coated magazine paper: almost no texture.
            return [
                (1, 0.5, 1.2, 0.04),
            ]
        }
    }

    static func apply(to page: CIImage, amount: Double, seed: Int, stock: PageLook.PaperStock = .plain) -> CIImage {
        let extent = page.extent
        // Sizes are set for a page about as tall as the screen, and scale with the image.
        let unit = max(extent.width, extent.height) / 2400
        // Each page starts from a different place in the noise.
        let shift = CGAffineTransform(translationX: CGFloat((seed * 7919) % 5003) * 7, y: CGFloat((seed * 104_729) % 4001) * 5)
        let a = CGFloat(min(max(amount, 0), 1))
        var output = page
        // The paper's own colour, multiplied in (linear light).
        switch stock {
        case .plain, .glossy:
            break
        case .newsprint:
            // Grey-yellow, and the ink a little short of black.
            output = tinted(output, red: 1 - 0.14 * a, green: 1 - 0.17 * a, blue: 1 - 0.30 * a, lift: 0.012 * a)
        case .cream:
            output = tinted(output, red: 1, green: 1 - 0.05 * a, blue: 1 - 0.18 * a, lift: 0)
        }
        for (index, layer) in layers(for: stock).enumerated() {
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
        if stock == .glossy {
            output = sheen(output, amount: a)
        }
        return output
    }

    private static func tinted(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat, lift: CGFloat) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: red - lift, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: green - lift, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: blue - lift, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: lift, y: lift, z: lift, w: 0)
        return filter.outputImage ?? image
    }

    /// A soft diagonal sheen, as light catches coated paper.
    private static func sheen(_ image: CIImage, amount: CGFloat) -> CIImage {
        let extent = image.extent
        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: extent.minX, y: extent.maxY)
        gradient.point1 = CGPoint(x: extent.midX, y: extent.midY)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.10 * amount)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        guard let light = gradient.outputImage?.cropped(to: extent) else { return image }
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = light
        screen.backgroundImage = image
        return screen.outputImage?.cropped(to: extent) ?? image
    }
}
