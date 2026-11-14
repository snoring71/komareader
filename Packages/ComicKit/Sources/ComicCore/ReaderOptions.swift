import Foundation

public extension BookRecord {
    /// A book's own reader settings. Every setting is optional: one that is left out means
    /// "use the app's default for books", so changing a default reaches every book that has
    /// not set that option itself.
    struct ReaderOptions: Codable, Equatable, Sendable {
        public typealias Direction = ReaderSettings.Direction

        public enum PageLayout: String, Codable, CaseIterable, Sendable {
            case single, double
        }

        public enum Fit: String, Codable, CaseIterable, Sendable {
            case screen, width, height
        }

        /// What fills the screen around the page.
        public enum Background: Codable, Hashable, Sendable {
            case black, gray, white
            /// Follows the colour at the edges of the page on screen.
            case dynamic
            /// A colour the user picked, as `#RRGGBB`.
            case custom(String)

            public init(code: String) {
                switch code {
                case "black": self = .black
                case "gray": self = .gray
                case "white": self = .white
                case "dynamic": self = .dynamic
                default: self = code.hasPrefix("#") && code.count == 7 ? .custom(code.uppercased()) : .black
                }
            }

            public var code: String {
                switch self {
                case .black: return "black"
                case .gray: return "gray"
                case .white: return "white"
                case .dynamic: return "dynamic"
                case .custom(let hex): return hex
                }
            }

            public init(from decoder: Decoder) throws {
                self.init(code: try decoder.singleValueContainer().decode(String.self))
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(code)
            }

            /// Red, green and blue from 0 to 1, for the fixed colours and custom ones.
            public var rgb: (red: Double, green: Double, blue: Double)? {
                switch self {
                case .black: return (0, 0, 0)
                case .gray: return (0.5, 0.5, 0.5)
                case .white: return (1, 1, 1)
                case .dynamic: return nil
                case .custom(let hex):
                    guard let value = UInt32(hex.dropFirst(), radix: 16) else { return (0, 0, 0) }
                    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
                }
            }

            public static func fromRGB(red: Double, green: Double, blue: Double) -> Background {
                func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
                return .custom(String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue)))
            }
        }

        /// Trims the margins of every page in the book. A book has left pages and right pages
        /// (as they sit in a two-page spread), and each side has its own crop, so the outer
        /// margins can be trimmed on both. Rectangles are `[x, y, width, height]` as fractions
        /// of a page. An image that holds two pages takes the left crop on its left half and
        /// the right crop on its right half; splitting it into two pages happens after that.
        public struct PageCrop: Codable, Equatable, Sendable {
            /// How the two crops relate while editing: `mirrored` (the right crop is the left
            /// one flipped side to side, for outer and inner margins), `same`, or `separate`.
            public enum Link: String, Codable, CaseIterable, Sendable { case mirrored, same, separate }

            public var left: [Double]
            public var right: [Double]
            public var link: Link

            public init(left: [Double], right: [Double], link: Link) {
                self.left = Self.valid(left)
                self.right = Self.valid(right)
                self.link = link
            }

            public static let none = [0.0, 0, 1, 1]

            /// `rect` flipped side to side.
            public static func mirror(_ rect: [Double]) -> [Double] {
                let r = valid(rect)
                return [max(0, 1 - r[0] - r[2]), r[1], r[2], r[3]]
            }

            private static func valid(_ rect: [Double]) -> [Double] { rect.count == 4 ? rect : none }

            /// The crop for a page on `side`. For an image holding two pages shown whole,
            /// the crop of the whole image: the left page's outer edge to the right page's,
            /// keeping the middle.
            public func rect(for side: PageSide) -> [Double] {
                switch side {
                case .left: return Self.valid(left)
                case .right: return Self.valid(right)
                case .both:
                    let l = Self.valid(left), r = Self.valid(right)
                    let minX = l[0] / 2, maxX = 0.5 + (r[0] + r[2]) / 2
                    let minY = min(l[1], r[1]), maxY = max(l[1] + l[3], r[1] + r[3])
                    return [minX, minY, maxX - minX, maxY - minY]
                }
            }

            public var isNone: Bool { Self.valid(left) == Self.none && Self.valid(right) == Self.none }
        }

        public var direction: Direction?
        public var portraitLayout: PageLayout?
        public var landscapeLayout: PageLayout?
        public var fit: Fit?
        public var background: Background?
        /// Strength of the shadow drawn where two pages meet, from 0 (none) to 1.
        public var bindingShadow: Double?
        /// Whether images holding two pages are shown as two separate pages.
        public var splitDoublePages: Bool?
        /// Only set per book; there is no default crop.
        public var crop: PageCrop?
        public var updatedAt: Date

        public init(updatedAt: Date = Date()) {
            self.updatedAt = updatedAt
        }

        /// True when nothing is set, so the book follows the defaults entirely.
        public var isEmpty: Bool {
            direction == nil && portraitLayout == nil && landscapeLayout == nil && fit == nil
                && background == nil && bindingShadow == nil && splitDoublePages == nil && crop == nil
        }
    }

    /// The book's reader options, falling back on the direction an older version saved.
    var effectiveReaderOptions: ReaderOptions {
        if let readerOptions { return readerOptions }
        var options = ReaderOptions(updatedAt: readerSettings?.updatedAt ?? .distantPast)
        options.direction = readerSettings?.direction
        return options
    }
}
