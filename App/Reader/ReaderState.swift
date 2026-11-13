import ArchiveKit
import ComicCore
import LibraryKit
import Observation
import UIKit

/// Everything the reader shows: which pages share the screen, where we are, and the settings.
@MainActor
@Observable
final class ReaderState {
    enum Layout: String, CaseIterable, Identifiable {
        case auto = "Automatic", single = "Single Page", double = "Two Pages"
        var id: String { rawValue }
    }

    /// How a page is sized on screen. Width and height let a page run past the screen and scroll.
    enum Fit: String, CaseIterable, Identifiable {
        case screen = "Fit Screen", width = "Fit Width", height = "Fit Height"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .screen: return "arrow.up.left.and.arrow.down.right"
            case .width: return "arrow.left.and.right"
            case .height: return "arrow.up.and.down"
            }
        }
    }

    let book: Book
    let source: BookSource
    let pageCount: Int

    var spreads: [[Int]] = []
    var currentSpread = 0
    var rightToLeft: Bool
    var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "readerLayout"); relayout() }
    }
    var fit: Fit {
        didSet { UserDefaults.standard.set(fit.rawValue, forKey: "readerFit"); layoutVersion += 1 }
    }
    var showChrome = true
    /// Bumped whenever `spreads` is rebuilt, so the page view reloads.
    private(set) var layoutVersion = 0

    @ObservationIgnored private var isLandscape = false
    @ObservationIgnored private var widePages: Set<Int> = []
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored let cache = PageImageCache()
    @ObservationIgnored private let thumbnails = NSCache<NSNumber, UIImage>()
    @ObservationIgnored var onPageChange: ((_ page: Int, _ finished: Bool) -> Void)?

    init(book: Book, source: BookSource) {
        self.book = book
        self.source = source
        self.pageCount = source.pageCount
        self.rightToLeft = book.direction == "rtl"
        self.layout = Layout(rawValue: UserDefaults.standard.string(forKey: "readerLayout") ?? "") ?? .auto
        self.fit = Fit(rawValue: UserDefaults.standard.string(forKey: "readerFit") ?? "") ?? .screen
        let start = min(max(0, book.finished ? 0 : (book.currentPage ?? 0)), max(0, source.pageCount - 1))
        spreads = SpreadLayout.spreads(pageCount: pageCount, twoPage: false) { _ in false }
        currentSpread = SpreadLayout.spreadIndex(containing: start, in: spreads)
        loadPageSizes()
    }

    var currentPages: [Int] { spreads.indices.contains(currentSpread) ? spreads[currentSpread] : [] }
    var currentPage: Int { currentPages.first ?? 0 }

    var pageLabel: String {
        let pages = currentPages.map { String($0 + 1) }.joined(separator: "–")
        return "\(pages) of \(pageCount)"
    }

    private var usesTwoPages: Bool {
        switch layout {
        case .auto: return isLandscape
        case .single: return false
        case .double: return true
        }
    }

    func setLandscape(_ landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        relayout()
    }

    private func relayout() {
        let page = currentPage
        let wide = widePages
        spreads = SpreadLayout.spreads(pageCount: pageCount, twoPage: usesTwoPages) { wide.contains($0) }
        currentSpread = SpreadLayout.spreadIndex(containing: page, in: spreads)
        layoutVersion += 1
        prefetch()
    }

    /// Reads page sizes in the background so wide pages can stand alone in two-page mode.
    private func loadPageSizes() {
        let source = source, count = pageCount
        sizeTask = Task { [weak self] in
            var wide: Set<Int> = []
            for index in 0..<count {
                if Task.isCancelled { return }
                if let size = try? await source.pageSize(at: index), size.width > size.height * 1.1 { wide.insert(index) }
            }
            guard let self, !Task.isCancelled else { return }
            self.widePages = wide
            if self.usesTwoPages { self.relayout() }
        }
    }

    func cancel() {
        sizeTask?.cancel()
        prefetchTask?.cancel()
    }

    // MARK: Navigation

    /// Called by the page view after the user swipes, or by the buttons and slider.
    func show(spread: Int) {
        let clamped = min(max(0, spread), max(0, spreads.count - 1))
        guard clamped != currentSpread else { return }
        currentSpread = clamped
        pageDidChange()
    }

    func next() { show(spread: currentSpread + 1) }
    func previous() { show(spread: currentSpread - 1) }

    func jump(toPage page: Int) {
        show(spread: SpreadLayout.spreadIndex(containing: page, in: spreads))
    }

    /// Tap zones: the outer thirds turn pages (mirrored for right-to-left), the middle shows controls.
    func handleTap(atFraction x: CGFloat) {
        if x < 0.3 {
            rightToLeft ? next() : previous()
        } else if x > 0.7 {
            rightToLeft ? previous() : next()
        } else {
            showChrome.toggle()
        }
    }

    private func pageDidChange() {
        let finished = currentPages.contains(pageCount - 1)
        onPageChange?(currentPage, finished)
        prefetch()
    }

    /// A small picture of a page for the scrubber preview, decoded off the main thread.
    func thumbnail(for page: Int) async -> UIImage? {
        if let cached = thumbnails.object(forKey: NSNumber(value: page)) { return cached }
        if let full = cache.image(for: page, minSize: 0) {
            return full
        }
        guard let image = try? await source.image(at: page, maxPixelSize: 360) else { return nil }
        let thumb = UIImage(cgImage: image)
        thumbnails.setObject(thumb, forKey: NSNumber(value: page))
        return thumb
    }

    /// Decodes two screens ahead and one behind at screen size.
    func prefetch() {
        prefetchTask?.cancel()
        let indices = [currentSpread + 1, currentSpread + 2, currentSpread - 1]
            .filter { spreads.indices.contains($0) }
            .flatMap { spreads[$0] }
        let source = source, cache = cache, size = PageImageCache.screenPixelSize
        prefetchTask = Task.detached(priority: .userInitiated) {
            for page in indices {
                if Task.isCancelled { return }
                _ = await cache.load(page: page, size: size, from: source)
            }
        }
    }
}

/// Decoded pages kept in memory, bounded by cost; the furthest pages go first under pressure.
final class PageImageCache: @unchecked Sendable {
    private let cache = NSCache<NSNumber, Entry>()
    private let lock = NSLock()
    /// Pages being decoded now, so the page view and the prefetcher share one decode
    /// instead of each doing the same work.
    private var loading: [Int: (size: CGFloat, task: Task<UIImage?, Never>)] = [:]

    final class Entry {
        let image: UIImage
        let size: CGFloat
        init(image: UIImage, size: CGFloat) { self.image = image; self.size = size }
    }

    init() {
        cache.totalCostLimit = 300 * 1024 * 1024
    }

    /// Longest screen side in pixels, which is what pages are decoded at until the user zooms.
    @MainActor static var screenPixelSize: CGFloat {
        let screen = UIScreen.main
        return max(screen.bounds.width, screen.bounds.height) * screen.scale
    }

    func image(for page: Int, minSize: CGFloat) -> UIImage? {
        guard let entry = cache.object(forKey: NSNumber(value: page)), entry.size >= minSize * 0.99 else { return nil }
        return entry.image
    }

    /// The page at `size`, from memory if it is there, otherwise decoded (once, however many callers ask).
    func load(page: Int, size: CGFloat, from source: BookSource) async -> UIImage? {
        if let cached = image(for: page, minSize: size) { return cached }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = loading[page], running.size >= size * 0.99 { return running.task }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
                let image = (try? await source.image(at: page, maxPixelSize: size)).map { UIImage(cgImage: $0) }
                guard let self else { return image }
                if let image { self.insert(image, for: page, size: size) }
                self.lock.withLock {
                    if let running = self.loading[page], running.size == size { self.loading[page] = nil }
                }
                return image
            }
            loading[page] = (size, task)
            return task
        }
        return await task.value
    }

    func insert(_ image: UIImage, for page: Int, size: CGFloat) {
        if let existing = cache.object(forKey: NSNumber(value: page)), existing.size >= size { return }
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(Entry(image: image, size: size), forKey: NSNumber(value: page), cost: cost)
    }
}
