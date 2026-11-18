import CoreGraphics
import Foundation

/// Small looks at a decoded page: the colour around its edges and where its margins end.
/// Both work on a tiny copy of the page, so they are cheap enough to run on every page turn.
public enum ImageAnalysis {
    public struct RGB: Equatable, Sendable {
        public var red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The average colour of the outermost pixels of `image`: what the screen around the page
    /// should be to look like more of the paper.
    public static func edgeColor(of image: CGImage) -> RGB? {
        let side = 24
        guard let pixels = rgba(image, width: side, height: side) else { return nil }
        var total = (r: 0, g: 0, b: 0), count = 0
        for y in 0..<side {
            for x in 0..<side where x < 2 || y < 2 || x >= side - 2 || y >= side - 2 {
                let i = (y * side + x) * 4
                total.r += Int(pixels[i]); total.g += Int(pixels[i + 1]); total.b += Int(pixels[i + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let scale = 255.0 * Double(count)
        return RGB(red: Double(total.r) / scale, green: Double(total.g) / scale, blue: Double(total.b) / scale)
    }

    /// The part of `image` inside its plain margins, as fractions `[x, y, width, height]`.
    /// A margin is a band of rows or columns along an edge that are (nearly) all the colour of
    /// the page's corners. Returns the whole page when there are no margins, or when trimming
    /// them would leave less than half the page (a mostly blank page, say).
    public static func contentBounds(of image: CGImage) -> [Double] {
        let whole = [0.0, 0, 1, 1]
        let longest = 320.0
        let scale = min(1, longest / Double(max(image.width, image.height)))
        let width = max(8, Int((Double(image.width) * scale).rounded()))
        let height = max(8, Int((Double(image.height) * scale).rounded()))
        guard let pixels = rgba(image, width: width, height: height) else { return whole }

        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        // The margin colour: the average of the four corners.
        let corners = [pixel(0, 0), pixel(width - 1, 0), pixel(0, height - 1), pixel(width - 1, height - 1)]
        var sum = (0, 0, 0)
        for corner in corners {
            sum.0 += corner.0
            sum.1 += corner.1
            sum.2 += corner.2
        }
        let reference = (sum.0 / 4, sum.1 / 4, sum.2 / 4)
        func isMargin(_ p: (Int, Int, Int)) -> Bool {
            abs(p.0 - reference.0) + abs(p.1 - reference.1) + abs(p.2 - reference.2) <= 60
        }
        // Allow a few stray pixels (scanner dust, JPEG noise) in a margin line.
        func rowIsMargin(_ y: Int) -> Bool {
            var misses = 0
            for x in 0..<width where !isMargin(pixel(x, y)) {
                misses += 1
                if misses > width / 100 + 1 { return false }
            }
            return true
        }
        func columnIsMargin(_ x: Int) -> Bool {
            var misses = 0
            for y in 0..<height where !isMargin(pixel(x, y)) {
                misses += 1
                if misses > height / 100 + 1 { return false }
            }
            return true
        }
        var top = 0, bottom = height - 1, left = 0, right = width - 1
        while top < bottom, rowIsMargin(top) { top += 1 }
        while bottom > top, rowIsMargin(bottom) { bottom -= 1 }
        while left < right, columnIsMargin(left) { left += 1 }
        while right > left, columnIsMargin(right) { right -= 1 }
        // Back off a pixel so the art's own edge is kept.
        top = max(0, top - 1); left = max(0, left - 1)
        bottom = min(height - 1, bottom + 1); right = min(width - 1, right + 1)
        let w = Double(right - left + 1) / Double(width), h = Double(bottom - top + 1) / Double(height)
        guard w >= 0.5, h >= 0.5 else { return whole }
        return [Double(left) / Double(width), Double(top) / Double(height), w, h]
    }

    /// `image` drawn at `width` × `height` as RGBA bytes, rows from the top.
    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
