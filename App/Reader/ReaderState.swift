import ArchiveKit
import ComicCore
import LibraryKit
import Observation
import UIKit

/// Everything the reader shows: which pages share the screen, where we are, and the settings.
@MainActor
@Observable
final class ReaderState {
    typealias Fit = ReaderOptions.Fit

    let book: Book
    let source: BookSource
    let pageCount: Int
    let defaults: ReaderDefaults

    /// What this book sets for itself; anything left out follows `defaults`.
    private(set) var options: ReaderOptions
    /// Every page in reading order, with images that hold two pages split in two when asked.
    private(set) var displayPages: [DisplayPage] = []
    var spreads: [[DisplayPage]] = []
    var currentSpread = 0
    var showChrome = true
    /// Bumped whenever `spreads` is rebuilt or a setting changes, so the page view reloads.
    private(set) var layoutVersion = 0

    @ObservationIgnored private var positions: [DisplayPage: Int] = [:]
    @ObservationIgnored private var isLandscape = false
    @ObservationIgnored private var widePages: Set<Int> = []
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored let cache = PageImageCache()
    /// Edge colours for Match Page backgrounds, so a page shown again gets its colour at once.
    @ObservationIgnored let edgeColors = NSCache<NSString, UIColor>()
    @ObservationIgnored private let thumbnails = NSCache<NSNumber, UIImage>()
    @ObservationIgnored var onPageChange: ((_ page: Int, _ finished: Bool) -> Void)?
    /// Called with the book's own settings whenever they change, to save them.
    @ObservationIgnored var onOptionsChange: ((ReaderOptions) -> Void)?

    init(book: Book, source: BookSource, options: ReaderOptions, defaults: ReaderDefaults) {
        self.book = book
        self.source = source
        self.pageCount = source.pageCount
        self.options = options
        self.defaults = defaults
        let start = min(max(0, book.finished ? 0 : (book.currentPage ?? 0)), max(0, source.pageCount - 1))
        rebuild(keeping: start)
        loadPageSizes()
    }

    // MARK: Settings (the book's own, else the defaults)

    var direction: ReaderOptions.Direction { options.direction ?? defaults.direction }
    var rightToLeft: Bool { direction == .rightToLeft }
    var portraitLayout: ReaderOptions.PageLayout { options.portraitLayout ?? defaults.portraitLayout }
    var landscapeLayout: ReaderOptions.PageLayout { options.landscapeLayout ?? defaults.landscapeLayout }
    var fit: Fit { options.fit ?? defaults.fit }
    var background: ReaderOptions.Background { options.background ?? defaults.background }
    var bindingShadow: Double { options.bindingShadow ?? defaults.bindingShadow }
    var splitDoublePages: Bool { options.splitDoublePages ?? defaults.splitDoublePages }
    var crop: ReaderOptions.PageCrop? { options.crop }

    /// Whether the book sets anything itself (other than its crop, which has no default).
    var hasOwnSettings: Bool {
        var settings = options
        settings.crop = nil
        return !settings.isEmpty
    }

    /// Every setting as the reader uses it now.
    var resolvedOptions: ReaderOptions {
        var resolved = options
        resolved.direction = direction
        resolved.portraitLayout = portraitLayout
        resolved.landscapeLayout = landscapeLayout
        resolved.fit = fit
        resolved.background = background
        resolved.bindingShadow = bindingShadow
        resolved.splitDoublePages = splitDoublePages
        return resolved
    }

    /// Changes this book's own settings, saves them and redraws.
    func change(_ edit: (inout ReaderOptions) -> Void) {
        var updated = options
        edit(&updated)
        guard updated != options else { return }
        updated.updatedAt = Date()
        options = updated
        onOptionsChange?(updated)
        relayout()
    }

    /// The book goes back to following the defaults (its crop stays).
    func resetToDefaults() {
        change { options in
            let crop = options.crop
            options = ReaderOptions(updatedAt: options.updatedAt)
            options.crop = crop
        }
    }

    /// Makes this book's settings the defaults for every book, and lets this one follow them.
    func useAsDefaults() {
        defaults.adopt(resolvedOptions)
        resetToDefaults()
    }

    /// Takes a direction changed elsewhere (Book Info) without saving it again.
    func adoptDirection(_ direction: ReaderOptions.Direction?) {
        guard direction != options.direction else { return }
        options.direction = direction
        relayout()
    }

    // MARK: Pages

    var currentDisplayPages: [DisplayPage] { spreads.indices.contains(currentSpread) ? spreads[currentSpread] : [] }

    /// The book's images on screen (one image twice in a row when both its halves are shown).
    var currentPages: [Int] {
        var pages: [Int] = []
        for page in currentDisplayPages where pages.last != page.page { pages.append(page.page) }
        return pages
    }

    var currentPage: Int { currentPages.first ?? 0 }

    /// Where the first page on screen is among `displayPages`.
    var currentPosition: Int { currentDisplayPages.first.flatMap { positions[$0] } ?? 0 }

    var pageLabel: String {
        let pages = currentPages.map { String($0 + 1) }.joined(separator: "–")
        return "\(pages) of \(pageCount)"
    }

    var isShowingLandscape: Bool { isLandscape }

    private var usesTwoPages: Bool {
        (isLandscape ? landscapeLayout : portraitLayout) == .double
    }

    func setLandscape(_ landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        relayout()
    }

    /// The crop for a page as shown, as fractions of the page (or its half); nil for none.
    func cropRect(for page: DisplayPage) -> CGRect? {
        guard let crop = options.crop, let position = positions[page] else { return nil }
        let rect = crop.rect(forPosition: position)
        guard rect != ReaderOptions.PageCrop.none else { return nil }
        return CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
    }

    private func relayout() {
        let shown = currentDisplayPages.first
        rebuild(keeping: currentPage, preferring: shown)
        layoutVersion += 1
        prefetch()
    }

    private func rebuild(keeping page: Int, preferring shown: DisplayPage? = nil) {
        let wide = widePages, split = splitDoublePages
        // The first image is left whole: when it is wide it is usually a wraparound cover.
        displayPages = SpreadLayout.displayPages(pageCount: pageCount, rightToLeft: rightToLeft) { split && $0 > 0 && wide.contains($0) }
        var positions: [DisplayPage: Int] = [:]
        for (position, page) in displayPages.enumerated() { positions[page] = position }
        self.positions = positions
        spreads = SpreadLayout.spreads(displayPages, twoPage: usesTwoPages) { wide.contains($0) }
        if let shown, let index = spreads.firstIndex(where: { $0.contains(shown) }) {
            currentSpread = index
        } else {
            currentSpread = SpreadLayout.spreadIndex(containing: page, in: spreads)
        }
    }

    /// Reads page sizes in the background so wide pages can stand alone in two-page mode
    /// (or be split in two).
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
            if !wide.isEmpty, self.usesTwoPages || self.splitDoublePages { self.relayout() }
        }
    }

    /// A page as shown (half of its image when split), without the crop, for the crop editor.
    func uncroppedImage(atPosition position: Int) async -> CGImage? {
        guard displayPages.indices.contains(position) else { return nil }
        let page = displayPages[position]
        guard let image = await cache.load(page: page.page, size: PageImageCache.screenPixelSize, from: source)?.cgImage else { return nil }
        return PagePieces.cut(image, part: page.part, crop: nil)
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
        var indices: [Int] = []
        for spread in [currentSpread + 1, currentSpread + 2, currentSpread - 1] where spreads.indices.contains(spread) {
            for page in spreads[spread] where !indices.contains(page.page) { indices.append(page.page) }
        }
        let source = source, cache = cache, size = PageImageCache.screenPixelSize
        prefetchTask = Task.detached(priority: .userInitiated) {
            for page in indices {
                if Task.isCancelled { return }
                _ = await cache.load(page: page, size: size, from: source)
            }
        }
    }
}

/// Cuts the part of a decoded image that is shown: one half of a double page, then the crop.
enum PagePieces {
    static func cut(_ image: CGImage, part: DisplayPage.Part, crop: CGRect?) -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var rect: CGRect
        switch part {
        case .whole: rect = CGRect(x: 0, y: 0, width: width, height: height)
        case .left: rect = CGRect(x: 0, y: 0, width: (width / 2).rounded(), height: height)
        case .right: rect = CGRect(x: (width / 2).rounded(), y: 0, width: width - (width / 2).rounded(), height: height)
        }
        if let crop {
            rect = CGRect(x: rect.minX + crop.minX * rect.width, y: rect.minY + crop.minY * rect.height,
                          width: crop.width * rect.width, height: crop.height * rect.height)
        }
        rect = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 1, rect.height >= 1, rect.size != CGSize(width: width, height: height) else { return image }
        return image.cropping(to: rect) ?? image
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
