import Foundation

/// A page as the reader shows it: a whole image, or one half of an image that holds two pages.
public struct DisplayPage: Hashable, Sendable, CustomStringConvertible {
    public enum Part: String, Hashable, Sendable { case whole, left, right }

    /// The image's index in the book.
    public let page: Int
    public let part: Part

    public init(page: Int, part: Part = .whole) {
        self.page = page
        self.part = part
    }

    public var isHalf: Bool { part != .whole }

    public var description: String {
        switch part {
        case .whole: return "\(page)"
        case .left: return "\(page)L"
        case .right: return "\(page)R"
        }
    }
}

/// Decides which pages share the screen in two-page mode.
public enum SpreadLayout {
    /// Groups page indices into screens, in reading order.
    /// In two-page mode the cover stands alone, wide pages (already spreads) stand alone,
    /// and other pages pair up.
    public static func spreads(pageCount: Int, twoPage: Bool, isWide: (Int) -> Bool) -> [[Int]] {
        let pages = (0..<max(0, pageCount)).map { DisplayPage(page: $0) }
        return spreads(pages, twoPage: twoPage, isWide: isWide).map { $0.map(\.page) }
    }

    /// The pages in reading order. An image for which `split` is true becomes two pages: its
    /// left half first in left-to-right books, its right half first in right-to-left ones.
    public static func displayPages(pageCount: Int, rightToLeft: Bool, split: (Int) -> Bool) -> [DisplayPage] {
        var result: [DisplayPage] = []
        result.reserveCapacity(pageCount)
        for page in 0..<max(0, pageCount) {
            if split(page) {
                result.append(DisplayPage(page: page, part: rightToLeft ? .right : .left))
                result.append(DisplayPage(page: page, part: rightToLeft ? .left : .right))
            } else {
                result.append(DisplayPage(page: page))
            }
        }
        return result
    }

    /// Groups display pages into screens, in reading order. In two-page mode the first page
    /// stands alone, the two halves of a split image share a screen (so the spread reads as
    /// it was drawn), unsplit wide images stand alone, and other pages pair up.
    public static func spreads(_ pages: [DisplayPage], twoPage: Bool, isWide: (Int) -> Bool) -> [[DisplayPage]] {
        guard !pages.isEmpty else { return [] }
        guard twoPage else { return pages.map { [$0] } }
        func halvesStart(at i: Int) -> Bool {
            i + 1 < pages.count && pages[i].isHalf && pages[i + 1].isHalf && pages[i].page == pages[i + 1].page
        }
        func pairable(_ i: Int) -> Bool {
            i < pages.count && !pages[i].isHalf && !isWide(pages[i].page)
        }
        var result: [[DisplayPage]] = []
        var index = 0
        if halvesStart(at: 0) {
            result.append([pages[0], pages[1]])
            index = 2
        } else {
            result.append([pages[0]])
            index = 1
        }
        while index < pages.count {
            if halvesStart(at: index) {
                result.append([pages[index], pages[index + 1]])
                index += 2
            } else if pairable(index) && pairable(index + 1) {
                result.append([pages[index], pages[index + 1]])
                index += 2
            } else {
                result.append([pages[index]])
                index += 1
            }
        }
        return result
    }

    /// The screen that shows `page`.
    public static func spreadIndex(containing page: Int, in spreads: [[Int]]) -> Int {
        spreads.firstIndex { $0.contains(page) } ?? max(0, min(page, spreads.count - 1))
    }

    /// The first screen that shows any part of image `page`.
    public static func spreadIndex(containing page: Int, in spreads: [[DisplayPage]]) -> Int {
        if let found = spreads.firstIndex(where: { $0.contains { $0.page == page } }) { return found }
        // Past the end, or not laid out yet: the nearest screen before it.
        let before = spreads.lastIndex { ($0.first?.page ?? 0) < page }
        return max(0, min(before ?? 0, spreads.count - 1))
    }
}
