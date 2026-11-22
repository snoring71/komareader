import ComicCore
import Foundation
import PDFKit

/// Reads a book file's own metadata (ComicInfo.xml, or a PDF's title and author), for books on the device.
public enum MetadataReader {
    /// Nil if the file could not be read. A file with no metadata gives an empty result.
    public static func read(url: URL, format: BookFormat) -> BookData? {
        switch format {
        case .pdf:
            guard let document = PDFDocument(url: url) else { return nil }
            let attributes = document.documentAttributes ?? [:]
            func value(_ key: PDFDocumentAttribute) -> String? {
                guard let text = (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return text
            }
            // PDFs have no publisher field; the app that made the file is not one.
            var info = BookData()
            info.title = value(.titleAttribute)
            info.writers = BookData.names(value(.authorAttribute))
            return info
        case .folder:
            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            guard let info = contents.first(where: { BookData.isComicInfo(path: $0.lastPathComponent) }) else { return BookData() }
            guard let data = try? Data(contentsOf: info) else { return nil }
            return BookData.comicInfo(data) ?? BookData()
        case .zip, .rar, .sevenZip, .tar, .epub:
            var data: Data?
            do {
                try LibArchive.forEachEntry(in: url) { path, reader in
                    guard BookData.isComicInfo(path: path) else { return .next }
                    data = try reader.readAll()
                    return .stop
                }
            } catch {
                return nil
            }
            return data.flatMap(BookData.comicInfo) ?? BookData()
        }
    }
}
