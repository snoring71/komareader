import ComicCore
import Foundation

public extension LibraryFilter {
    /// Whether a book passes the filter's rules (#80). Plain words (`text`) are matched by the
    /// caller, which has the search keys for Japanese readings; `matchesText` does that.
    func matches(_ book: Book, now: Date = Date(), matchesText: (Book) -> Bool) -> Bool {
        let words = (text ?? "").trimmingCharacters(in: .whitespaces)
        if !words.isEmpty, !matchesText(book) { return false }
        guard !rules.isEmpty else { return true }
        switch match {
        case .all: return rules.allSatisfy { $0.matches(book, now: now) }
        case .any: return rules.contains { $0.matches(book, now: now) }
        }
    }
}

public extension LibraryFilter.Rule {
    func matches(_ book: Book, now: Date = Date()) -> Bool {
        switch field.kind {
        case .text:
            let value: [String]
            switch field {
            case .title: value = [book.title] + (book.info.title.map { [$0] } ?? [])
            case .series: value = [book.series]
            case .author: value = book.info.creators.map(\.name)
            case .publisher: value = [book.publisher, book.info.imprint].compactMap { $0 }
            case .folder: value = [book.folder]
            case .language: value = book.info.language.map { [$0] } ?? []
            default: value = []
            }
            return matchText(value)
        case .list:
            let have = field == .tag ? book.tags + (book.info.tags ?? []) : (book.info.genres ?? [])
            return matchList(have.map(Self.fold))
        case .choice:
            let have: String = field == .format ? book.format.rawValue : book.status.rawValue
            let wanted = values.map { $0.lowercased() }
            let hit = wanted.contains(have) || (field == .format && wanted.contains(book.format.displayName.lowercased()))
            return op == .isNoneOf ? !hit : hit
        case .flag:
            let value: Bool
            switch field {
            case .favorite: value = book.favorite
            case .bookmarked: value = book.hasBookmarks
            default: value = book.isDownloaded
            }
            return op == .isFalse ? !value : value
        case .number:
            let value: Int?
            switch field {
            case .year: value = book.info.year
            case .rating: value = book.rating
            default: value = book.pageCount
            }
            let numbers = values.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            // "Rating is at most 0" means not rated.
            if field == .rating, op == .atMost, numbers.first == 0 { return value == nil }
            guard let value, let first = numbers.first else { return false }
            switch op {
            case .atLeast: return value >= first
            case .atMost: return value <= first
            case .between: return value >= first && value <= (numbers.count > 1 ? numbers[1] : first)
            default: return value == first
            }
        case .date:
            let date: Date?
            switch field {
            case .added: date = book.addedAt
            case .lastRead: date = book.lastReadAt
            default: date = book.finished ? book.lastReadAt : nil
            }
            switch op {
            case .isSet: return date != nil
            case .isNotSet: return date == nil
            default:
                let days = Double(values.first.flatMap { Int($0) } ?? 30)
                let start = now.addingTimeInterval(-days * 86_400)
                let recent = date.map { $0 >= start } ?? false
                return op == .notInLast ? !recent : recent
            }
        }
    }

    /// Case, width and kana type ignored, as in search (#106).
    static func fold(_ text: String) -> String { SearchKey.fold(text) }

    private func matchText(_ have: [String]) -> Bool {
        guard let wanted = values.first.map(Self.fold), !wanted.isEmpty else { return true }
        let folded = have.map(Self.fold)
        switch op {
        case .is: return folded.contains(wanted)
        case .isNot: return !folded.contains(wanted)
        case .beginsWith: return folded.contains { $0.hasPrefix(wanted) }
        default: return folded.contains { $0.contains(wanted) }
        }
    }

    private func matchList(_ have: [String]) -> Bool {
        let wanted = values.map(Self.fold).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        switch op {
        case .isAllOf: return wanted.allSatisfy(have.contains)
        case .isNoneOf: return !wanted.contains(where: have.contains)
        default: return wanted.contains(where: have.contains)
        }
    }
}
