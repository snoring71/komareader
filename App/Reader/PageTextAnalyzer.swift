import UIKit
import VisionKit

/// Finds the text on pages with Live Text (VisionKit), on the device, so the reader can
/// select, copy, look up and translate it. Results are kept for the last few pages.
@MainActor
final class PageTextAnalyzer {
    /// Live Text needs an A12 chip or later; the reader hides Select Text where it is missing.
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    private let analyzer = ImageAnalyzer()
    private let configuration: ImageAnalyzer.Configuration
    private var results: [Int: (pixels: CGFloat, analysis: ImageAnalysis)] = [:]
    /// Pages from oldest to newest use, so the oldest result goes first.
    private var recent: [Int] = []
    private let limit = 12

    init(rightToLeft: Bool) {
        var configuration = ImageAnalyzer.Configuration([.text])
        // Japanese goes first in manga, so vertical and kana text is read as Japanese;
        // English stays in the list for sound effects and Latin text.
        configuration.locales = rightToLeft ? ["ja-JP", "en-US"] : ["en-US", "ja-JP"]
        self.configuration = configuration
    }

    /// The text on a page, read from `image`. A result from an image at least this sharp is reused.
    func analysis(page: Int, image: UIImage) async -> ImageAnalysis? {
        let pixels = max(image.size.width, image.size.height) * image.scale
        if let hit = results[page], hit.pixels >= pixels * 0.99 {
            touch(page)
            return hit.analysis
        }
        guard let analysis = try? await analyzer.analyze(image, configuration: configuration) else {
            return nil
        }
        if let existing = results[page], existing.pixels > pixels { return existing.analysis }
        results[page] = (pixels, analysis)
        touch(page)
        while recent.count > limit {
            results[recent.removeFirst()] = nil
        }
        return analysis
    }

    /// What has been read so far from these pages, in reading order, for Copy All Text.
    func transcript(pages: [Int]) -> String {
        pages.compactMap { results[$0]?.analysis.transcript }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func touch(_ page: Int) {
        recent.removeAll { $0 == page }
        recent.append(page)
    }
}
