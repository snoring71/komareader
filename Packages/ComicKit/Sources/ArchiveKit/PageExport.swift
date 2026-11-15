import CoreGraphics
import Foundation

/// A page as it is in the book, written to a file for the share sheet: the original image
/// file, untouched, for archives and image folders; a full-resolution JPEG for PDFs, which
/// have no image file. Nothing the reader does to pages (crop, split halves, contrast,
/// sharpness, paper grain) is applied.
public enum PageExport {
    /// Writes page `index` into `directory` as `"<title> - p<number>.<ext>"` and returns the file.
    public static func export(_ source: BookSource, page index: Int, title: String, to directory: URL) async throws -> URL {
        guard index >= 0, index < source.pageCount else { throw ArchiveError(message: "No page \(index + 1)") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original: URL?
        switch source {
        case let archive as ArchiveBookSource:
            original = try await archive.pageURL(at: index)
        case let folder as FolderBookSource:
            original = folder.pageURLs[index]
        default:
            original = nil
        }
        if let original {
            let ext = original.pathExtension.isEmpty ? "jpg" : original.pathExtension.lowercased()
            let destination = directory.appendingPathComponent(fileName(title: title, page: index, ext: ext))
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: original, to: destination)
            return destination
        }
        let image: CGImage
        if let pdf = source as? PDFBookSource {
            image = try await Task.detached(priority: .userInitiated) { try pdf.renderOriginal(index: index) }.value
        } else {
            image = try await source.image(at: index, maxPixelSize: maxPixelSize)
        }
        guard let jpeg = ImageDecoder.jpegData(image, quality: 0.92) else { throw ArchiveError(message: "Could not encode the page") }
        let destination = directory.appendingPathComponent(fileName(title: title, page: index, ext: "jpg"))
        try jpeg.write(to: destination, options: .atomic)
        return destination
    }

    /// Longest side of an exported rendering, so a huge PDF page can't run out of memory.
    static let maxPixelSize: CGFloat = 10_000

    /// `"Book Title - p12.jpg"` for page index 11, with characters that file names can't hold replaced.
    public static func fileName(title: String, page index: Int, ext: String) -> String {
        var name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix(".") { name = String(name.drop { $0 == "." }) }
        if name.isEmpty { name = "Page" }
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return "\(name) - p\(index + 1).\(ext)"
    }
}
