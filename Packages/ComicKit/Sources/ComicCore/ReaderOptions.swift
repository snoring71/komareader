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
        /// Page contrast, from -1 (flatter) through 0 (unchanged) to 1 (punchier).
        public var contrast: Double?
        /// Page sharpening, from 0 (none) to 1.
        public var sharpness: Double?
        /// A printed-paper texture over the page, from 0 (none) to 1.
        public var paperGrain: Double?
        /// A warm, aged-paper tint, from 0 (none) to 1.
        public var paperTint: Double?
        /// Page brightness, from -1 (darker) through 0 to 1 (lighter).
        public var brightness: Double?
        /// Midtones, from -1 (darker) through 0 to 1 (lighter), leaving black and white alone.
        public var gamma: Double?
        /// Colour strength, from -1 (grey) through 0 to 1 (stronger).
        public var saturation: Double?
        /// Shows pages in shades of grey, for black-and-white scans with a colour cast.
        public var blackAndWhite: Bool?
        /// Sets each page's white point, black point and tint from the page itself, so
        /// yellowed paper turns white and faded ink black.
        public var autoFix: Bool?
        /// A page mode for reading in the dark.
        public var nightMode: NightMode?
        /// Uses `nightMode` only while the system appearance is dark.
        public var nightOnlyInDark: Bool?
        /// Softens halftone dots and JPEG blocks, from 0 (none) to 1.
        public var descreen: Double?
        /// Resizes pages to the exact size on screen with Lanczos resampling.
        public var sharperScaling: Bool?
        /// Leaves colour pages in colour when a black-and-white fix (black and white, auto-fix's
        /// tint removal, sepia) is on.
        public var keepColorPages: Bool?
        /// Which paper `paperGrain` draws.
        public var paperStock: PaperStock?
        /// Trims each page's blank border as it loads (a hand-set `crop` wins).
        public var autoTrim: Bool?
        /// Only set per book; there is no default crop.
        public var crop: PageCrop?
        public var updatedAt: Date

        public enum NightMode: String, Codable, CaseIterable, Sendable {
            case off, sepia, dim, invert

            /// A mode from a newer version reads as off, rather than failing the whole record.
            public init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .off
            }
        }

        public enum PaperStock: String, Codable, CaseIterable, Sendable {
            /// The scanner-grey grain from #44.
            case plain
            case newsprint, cream, glossy

            public init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .plain
            }
        }

        public init(updatedAt: Date = Date()) {
            self.updatedAt = updatedAt
        }

        /// True when nothing is set, so the book follows the defaults entirely.
        public var isEmpty: Bool {
            direction == nil && portraitLayout == nil && landscapeLayout == nil && fit == nil
                && background == nil && bindingShadow == nil && splitDoublePages == nil && crop == nil
                && contrast == nil && sharpness == nil && paperGrain == nil && paperTint == nil
                && !hasLookExtras && autoTrim == nil
        }

        /// Whether any of the image settings added in phase 3 is set.
        var hasLookExtras: Bool {
            brightness != nil || gamma != nil || saturation != nil || blackAndWhite != nil || autoFix != nil
                || nightMode != nil || nightOnlyInDark != nil || descreen != nil || sharperScaling != nil
                || keepColorPages != nil || paperStock != nil
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
