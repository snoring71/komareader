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

        /// Trims every page of the book by the same amount, for books with wide margins.
        /// Rectangles are `[x, y, width, height]` as fractions of the page as shown (after a
        /// double page is split, of each half).
        public struct PageCrop: Codable, Equatable, Sendable {
            /// The crop for odd pages (1, 3, 5, …, counted as shown), and for every page when
            /// `even` is left out.
            public var odd: [Double]
            /// The crop for even pages, for books whose margins alternate.
            public var even: [Double]?

            public init(odd: [Double], even: [Double]? = nil) {
                self.odd = odd
                self.even = even
            }

            public static let none = [0.0, 0, 1, 1]

            /// The crop for the page shown at `position` (0 is page 1).
            public func rect(forPosition position: Int) -> [Double] {
                let rect = position % 2 == 1 ? (even ?? odd) : odd
                return rect.count == 4 ? rect : Self.none
            }
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
