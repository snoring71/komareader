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

    /// The crop that trims plain margins from a cover, as fractions `[x, y, width, height]`,
    /// or nil when there are none.
    ///
    /// A margin is a band along an edge whose colour is white, black or grey (not a coloured
    /// border) and whose lines are mostly that colour: up to `watermarkShare` of a line may
    /// differ, so a watermark printed in the band does not stop it. Bands can be stacked (a grey
    /// frame around a white half page, say): each is measured with its own colour. A band is not
    /// a margin if some art runs right across it (a title strip reaching the page edge), and
    /// bands thinner than `minimumBand` of the page are left alone. Left and right come first;
    /// then top and bottom are looked at between those, and trimmed only if their band is no
    /// more than `maximumTopBottom` of the height. Each trimmed edge goes one pixel further in,
    /// so a blurred or JPEG-smudged edge between band and art is not kept. Sides are not trimmed
    /// if less than a fifth of the width would be left (a blank page, say).
    public static func marginCrop(of image: CGImage, minimumBand: Double = 0.004, watermarkShare: Double = 0.15,
                                  maximumTopBottom: Double = 0.05) -> [Double]? {
        // Measured on a copy no bigger than the shared cover, so "one pixel" is a cover pixel.
        let longest = 1200.0
        let scale = min(1, longest / Double(max(image.width, image.height)))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width >= 16, height >= 16, let pixels = rgba(image, width: width, height: height) else { return nil }

        typealias Colour = (r: Int, g: Int, b: Int)
        /// One edge's lines: columns (for left and right) or rows (for top and bottom), counted
        /// from the edge inwards, each looked at across `across`.
        struct Edge {
            var vertical: Bool
            var start: Int
            var step: Int
            var count: Int
            var across: Range<Int>
        }
        func pixel(_ edge: Edge, line: Int, at position: Int) -> Colour {
            let l = edge.start + edge.step * line
            let (x, y) = edge.vertical ? (l, position) : (position, l)
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func differs(_ p: Colour, _ reference: Colour) -> Bool {
            abs(p.r - reference.r) + abs(p.g - reference.g) + abs(p.b - reference.b) > 48
        }
        /// The typical colour of two lines (each channel's median), if it is white, black or grey.
        func neutralReference(_ edge: Edge, line: Int) -> Colour? {
            var reds: [Int] = [], greens: [Int] = [], blues: [Int] = []
            for l in [line, line + 1] {
                for position in edge.across {
                    let p = pixel(edge, line: l, at: position)
                    reds.append(p.r); greens.append(p.g); blues.append(p.b)
                }
            }
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            let colour = (r: median(reds), g: median(greens), b: median(blues))
            return max(colour.r, colour.g, colour.b) - min(colour.r, colour.g, colour.b) <= 24 ? colour : nil
        }
        /// How many lines in from the edge are margin, band after band.
        func margin(_ edge: Edge) -> Int {
            let span = edge.across.count
            guard span > 0 else { return 0 }
            let allowedMisses = Int(Double(span) * watermarkShare)
            func lineMatches(_ line: Int, _ reference: Colour) -> Bool {
                var misses = 0
                for position in edge.across where differs(pixel(edge, line: line, at: position), reference) {
                    misses += 1
                    if misses > allowedMisses { return false }
                }
                return true
            }
            var done = 0
            while done < edge.count - 1 {
                // A new band may start a line or two in, past the blurred seam with the last one.
                var found: (start: Int, length: Int, reference: Colour)?
                for offset in 0..<(done == 0 ? 1 : 3) {
                    let first = done + offset
                    guard first + 1 < edge.count, let reference = neutralReference(edge, line: first) else { continue }
                    var length = 0
                    while first + length < edge.count, lineMatches(first + length, reference) { length += 1 }
                    if length >= 2 {
                        found = (first, length, reference)
                        break
                    }
                }
                guard let band = found else { break }
                // Art running right across the band (on more than 1% of it) means it is not a margin.
                var crossings = 0
                for position in edge.across {
                    var misses = 0
                    for line in band.start..<(band.start + band.length)
                    where differs(pixel(edge, line: line, at: position), band.reference) { misses += 1 }
                    if Double(misses) >= Double(band.length) * 0.9 { crossings += 1 }
                }
                guard Double(crossings) <= Double(span) * 0.01 else { break }
                done = band.start + band.length
            }
            return done
        }
        /// A band thick enough to trim, plus the extra pixel; otherwise 0.
        func trim(_ band: Int, of size: Int) -> Int {
            band >= max(3, Int((Double(size) * minimumBand).rounded())) ? band + 1 : 0
        }

        var left = trim(margin(Edge(vertical: true, start: 0, step: 1, count: width, across: 0..<height)), of: width)
        var right = trim(margin(Edge(vertical: true, start: width - 1, step: -1, count: width, across: 0..<height)), of: width)
        if Double(width - left - right) < Double(width) * 0.2 { left = 0; right = 0 }
        let columns = left..<(width - right)
        let tallest = Int(Double(height) * maximumTopBottom)
        var top = trim(margin(Edge(vertical: false, start: 0, step: 1, count: height, across: columns)), of: height)
        var bottom = trim(margin(Edge(vertical: false, start: height - 1, step: -1, count: height, across: columns)), of: height)
        if top > tallest + 1 { top = 0 }
        if bottom > tallest + 1 { bottom = 0 }
        guard left > 0 || right > 0 || top > 0 || bottom > 0 else { return nil }
        func rounded(_ value: Double) -> Double { (value * 10000).rounded() / 10000 }
        return [rounded(Double(left) / Double(width)), rounded(Double(top) / Double(height)),
                rounded(Double(width - left - right) / Double(width)), rounded(Double(height - top - bottom) / Double(height))]
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
