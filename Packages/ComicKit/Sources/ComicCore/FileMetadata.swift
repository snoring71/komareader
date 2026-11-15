import Foundation

/// Facts a book file says about itself: ComicInfo.xml in archives and image folders, the
/// document attributes in PDFs. Kept in the local index only; the synced record's `metadata`
/// group is for the user's own edits.
public struct FileMetadata: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var publisher: String?

    public init(title: String? = nil, author: String? = nil, publisher: String? = nil) {
        self.title = title
        self.author = author
        self.publisher = publisher
    }

    public var isEmpty: Bool { title == nil && author == nil && publisher == nil }

    /// Reads the fields the library shows from a ComicInfo.xml (the ComicRack format).
    /// The author is the writer, else the penciller. Returns nil if it is not ComicInfo XML.
    public static func comicInfo(_ data: Data) -> FileMetadata? {
        let reader = ComicInfoReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse(), reader.isComicInfo else { return nil }
        let fields = reader.fields
        func value(_ key: String) -> String? {
            guard let text = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        return FileMetadata(title: value("title"), author: value("writer") ?? value("penciller"), publisher: value("publisher"))
    }

    /// Text that has the look of an entry name for ComicInfo.xml, at any depth, in any case.
    public static func isComicInfo(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !path.contains("__MACOSX") else { return false }
        return name.caseInsensitiveCompare("ComicInfo.xml") == .orderedSame
    }
}

private final class ComicInfoReader: NSObject, XMLParserDelegate {
    var isComicInfo = false
    var fields: [String: String] = [:]
    private var depth = 0
    private var current: String?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        depth += 1
        if depth == 1 { isComicInfo = name.caseInsensitiveCompare("ComicInfo") == .orderedSame }
        if depth == 2 {
            current = name.lowercased()
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2, let current, fields[current] == nil { fields[current] = text }
        if depth == 2 { current = nil }
        depth -= 1
    }
}
