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
    /// Keyed by what is shown (image, half and crop), with the size it was read at.
    private var results: [String: (pixels: CGFloat, analysis: ImageAnalysis)] = [:]
    private var running: [String: (pixels: CGFloat, task: Task<ImageAnalysis?, Never>)] = [:]
    /// The last analysis queued. Each waits for the one before: two pages read at the same
    /// time sometimes left one of them with no text at all.
    private var queueTail: Task<Void, Never>?
    /// Keys from oldest to newest use, so the oldest result goes first.
    private var recent: [String] = []
    private let limit = 16

    init() {
        // No locale list, as in the Photos app, so Live Text picks the language itself. Photos
        // found text on a manga page that this missed when asked for ja-JP and en-US.
        configuration = ImageAnalyzer.Configuration([.text])
    }

    /// The text on a page, read from `image`. A result from an image at least this sharp is reused.
    func analysis(key: String, image: UIImage) async -> ImageAnalysis? {
        let pixels = max(image.size.width, image.size.height) * image.scale
        if let hit = results[key], hit.pixels >= pixels * 0.99 {
            touch(key)
            return hit.analysis
        }
        if let current = running[key], current.pixels >= pixels * 0.99 {
            return await current.task.value
        }
        let previous = queueTail
        let analyzer = analyzer, configuration = configuration
        // Not tied to the caller, so a page that scrolls away doesn't cancel work another page shares.
        let task = Task { @MainActor () -> ImageAnalysis? in
            await previous?.value
            // One retry: a failed read is usually a busy analyzer, not a page without text.
            for attempt in 0..<2 {
                if let analysis = await Self.analyze(image, with: analyzer, configuration: configuration) {
                    return analysis
                }
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(300)) }
            }
            return nil
        }
        queueTail = Task { _ = await task.value }
        running[key] = (pixels, task)
        let analysis = await task.value
        if running[key]?.task == task { running[key] = nil }
        guard let analysis else { return nil }
        if let existing = results[key], existing.pixels > pixels { return existing.analysis }
        results[key] = (pixels, analysis)
        touch(key)
        while recent.count > limit {
            results[recent.removeFirst()] = nil
        }
        return analysis
    }

    /// One read, given up after a while: a read that never ends would hold up every page queued after it.
    private static func analyze(_ image: UIImage, with analyzer: ImageAnalyzer, configuration: ImageAnalyzer.Configuration) async -> ImageAnalysis? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ImageAnalysis?, Never>) in
            let once = Once(continuation)
            Task { @MainActor in
                once.resume(try? await analyzer.analyze(image, configuration: configuration))
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                once.resume(nil)
            }
        }
    }

    /// Resumes a continuation the first time only (both callers run on the main actor).
    private final class Once: @unchecked Sendable {
        private var continuation: CheckedContinuation<ImageAnalysis?, Never>?
        init(_ continuation: CheckedContinuation<ImageAnalysis?, Never>) { self.continuation = continuation }
        func resume(_ value: ImageAnalysis?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }
}
