import Foundation

/// Decides which pages share the screen in two-page mode.
public enum SpreadLayout {
    /// Groups page indices into screens, in reading order.
    /// In two-page mode the cover stands alone, wide pages (already spreads) stand alone,
    /// and other pages pair up.
    public static func spreads(pageCount: Int, twoPage: Bool, isWide: (Int) -> Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard twoPage else { return (0..<pageCount).map { [$0] } }
        var result: [[Int]] = [[0]]
        var index = 1
        while index < pageCount {
            if isWide(index) || index + 1 >= pageCount || isWide(index + 1) {
                result.append([index])
                index += 1
            } else {
                result.append([index, index + 1])
                index += 2
            }
        }
        return result
    }

    /// The screen that shows `page`.
    public static func spreadIndex(containing page: Int, in spreads: [[Int]]) -> Int {
        spreads.firstIndex { $0.contains(page) } ?? max(0, min(page, spreads.count - 1))
    }
}
