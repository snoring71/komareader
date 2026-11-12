import Foundation

/// The order used for pages inside a book and for titles in the library.
///
/// It matches what Windows Explorer, Finder and other comic readers do:
///
/// - Runs of digits compare as numbers, so "Page 2" comes before "Page 10".
/// - Punctuation and spaces come before digits, and digits before letters, so "_01.jpg"
///   comes before "01.jpg", which comes before "a.jpg".
/// - Case, full-width forms and accents are ignored.
///
/// The rules do not depend on the device's language, so every device (and the Windows app)
/// puts the pages of a book in the same order and a synced page number means the same page.
public struct NaturalSortKey: Comparable, Sendable {
    private enum Part: Equatable, Sendable {
        case symbol(UInt32)
        /// Digits without leading zeros.
        case number(String)
        case letter(UInt32)

        var rank: Int {
            switch self {
            case .symbol: return 0
            case .number: return 1
            case .letter: return 2
            }
        }

        static func < (a: Part, b: Part) -> Bool {
            switch (a, b) {
            case let (.symbol(x), .symbol(y)), let (.letter(x), .letter(y)):
                return x < y
            case let (.number(x), .number(y)):
                return x.utf8.count != y.utf8.count ? x.utf8.count < y.utf8.count : x < y
            default:
                return a.rank < b.rank
            }
        }
    }

    private let parts: [Part]
    private let original: String

    public init(_ string: String) {
        original = string
        let folded = string.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
        var parts: [Part] = []
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            let trimmed = String(digits.drop { $0 == "0" })
            parts.append(.number(trimmed.isEmpty ? "0" : trimmed))
            digits = ""
        }
        for scalar in folded.unicodeScalars {
            if scalar.value >= 0x30, scalar.value <= 0x39 {
                digits.unicodeScalars.append(scalar)
                continue
            }
            flush()
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                parts.append(.letter(scalar.value))
            } else {
                parts.append(.symbol(scalar.value))
            }
        }
        flush()
        self.parts = parts
    }

    public static func < (a: NaturalSortKey, b: NaturalSortKey) -> Bool {
        for (x, y) in zip(a.parts, b.parts) where x != y {
            return x < y
        }
        if a.parts.count != b.parts.count { return a.parts.count < b.parts.count }
        // The same apart from case, width or leading zeros: fall back to the exact text,
        // so the order never depends on the order the names arrived in.
        return a.original.unicodeScalars.lexicographicallyPrecedes(b.original.unicodeScalars)
    }

    public static func == (a: NaturalSortKey, b: NaturalSortKey) -> Bool {
        a.original == b.original
    }
}

public extension String {
    /// See `NaturalSortKey`. To sort many strings, use `naturallySorted()` or keep the keys.
    func naturalLess(than other: String) -> Bool {
        NaturalSortKey(self) < NaturalSortKey(other)
    }
}

public extension Sequence where Element == String {
    func naturallySorted() -> [String] { naturallySorted(by: { $0 }) }
}

public extension Sequence {
    /// Sorts by a name in natural order, working out each element's sort key only once.
    func naturallySorted(by name: (Element) -> String) -> [Element] {
        map { (NaturalSortKey(name($0)), $0) }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }
}

public enum PageOrder {
    /// Entry paths of an archive in reading order: folder by folder, each in natural order.
    /// Paths are compared one folder name at a time, so "a/2.jpg" comes before "a b/1.jpg".
    public static func sorted(_ paths: [String]) -> [String] {
        paths.map { path in (path.split(separator: "/").map { NaturalSortKey(String($0)) }, path) }
            .sorted { a, b in
                for (x, y) in zip(a.0, b.0) where x != y { return x < y }
                if a.0.count != b.0.count { return a.0.count < b.0.count }
                return a.1 < b.1
            }
            .map(\.1)
    }
}
