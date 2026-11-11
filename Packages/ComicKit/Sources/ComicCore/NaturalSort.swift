import Foundation

public extension String {
    /// Finder-style ordering: "Page 2" sorts before "Page 10", case and width are ignored.
    func naturalLess(than other: String) -> Bool {
        compare(other, options: [.numeric, .caseInsensitive, .widthInsensitive, .diacriticInsensitive]) == .orderedAscending
    }
}

public extension Sequence where Element == String {
    func naturallySorted() -> [String] { sorted { $0.naturalLess(than: $1) } }
}
