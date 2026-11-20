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
    /// The controls start hidden; a tap in the middle shows them, and turning the page hides them.
    var showChrome = false
    /// Select Text mode: Live Text finds the words on the page so they can be selected,
    /// copied, looked up or translated. Off, the page takes no touches besides paging and zoom.
    var selectingText = false {
        didSet { if !selectingText { textStatus = .idle } }
    }
    /// What Live Text found on the screen showing now.
    var textStatus: TextStatus = .idle
    /// Bumped by Try Again, so the page view reads the pages that failed once more.
    private(set) var textRetry = 0

    func retryText() {
        textStatus = .searching
        textRetry += 1
    }

    enum TextStatus: Equatable {
        case idle, searching, found, none, failed
        /// Text on one page of the spread, nothing found on the other.
        case partial
    }
    /// Bumped whenever `spreads` is rebuilt or a setting changes, so the page view reloads.
    private(set) var layoutVersion = 0

    /// Which side of a printed spread each image sits on, for the crop.
    @ObservationIgnored private(set) var sides: [PageSide] = []
    /// The images grouped as the two-page layout would show them, for the crop editor.
    @ObservationIgnored private var pairs: [[Int]] = []
    @ObservationIgnored private var isLandscape = false
    @ObservationIgnored private var widePages: Set<Int> = []
    @ObservationIgnored private var sizeTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored let cache = PageImageCache()
    /// Edge colours for Match Page backgrounds, so a page shown again gets its colour at once.
    @ObservationIgnored let edgeColors = NSCache<NSString, UIColor>()
    @ObservationIgnored private let thumbnails = NSCache<NSNumber, UIImage>()
    @ObservationIgnored let textAnalyzer: PageTextAnalyzer
    /// All the text found on the screen showing now, in reading order (set by the page view).
    @ObservationIgnored var currentTranscript: () -> String = { "" }
    @ObservationIgnored var onPageChange: ((_ page: Int, _ finished: Bool) -> Void)?
    /// Called with the book's own settings whenever they change, to save them.
    @ObservationIgnored var onOptionsChange: ((ReaderOptions) -> Void)?
    /// Called with the bookmarked pages whenever they change, to save them.
    @ObservationIgnored var onBookmarksChange: (([Int]) -> Void)?

    /// Bookmarked pages (image indexes), sorted.
    private(set) var bookmarks: [Int]

    init(book: Book, source: BookSource, options: ReaderOptions, defaults: ReaderDefaults, bookmarks: [Int]? = nil) {
        self.book = book
        self.source = source
        self.pageCount = source.pageCount
        self.options = options
        self.defaults = defaults
        self.bookmarks = Array(Set(bookmarks ?? book.pageBookmarks)).filter { $0 >= 0 && $0 < source.pageCount }.sorted()
        self.textAnalyzer = PageTextAnalyzer()
        rebuild(keeping: Self.startPage(for: book, pageCount: source.pageCount))
        loadPageSizes()
    }

    /// Where a book opens: a finished book on its last page (so opening and closing it keeps
    /// it Read), any other book where it was left.
    static func startPage(for book: Book, pageCount: Int) -> Int {
        let page = book.finished ? pageCount - 1 : (book.currentPage ?? 0)
        return min(max(0, page), max(0, pageCount - 1))
    }

    // MARK: Bookmarks

    /// The bookmarked pages on screen now.
    var bookmarksOnScreen: [Int] { currentPages.filter { bookmarks.contains($0) } }

    var isBookmarkedHere: Bool { !bookmarksOnScreen.isEmpty }

    /// Bookmarks the page on screen (in a two-page spread, the first page in reading order),
    /// or removes the bookmarks on screen if there are any.
    func toggleBookmark() {
        let here = bookmarksOnScreen
        if here.isEmpty {
            setBookmarks(bookmarks + [currentPage])
        } else {
            setBookmarks(bookmarks.filter { !here.contains($0) })
        }
    }

    func removeBookmark(_ page: Int) {
        setBookmarks(bookmarks.filter { $0 != page })
    }

    private func setBookmarks(_ pages: [Int]) {
        let sorted = Array(Set(pages)).sorted()
        guard sorted != bookmarks else { return }
        bookmarks = sorted
        onBookmarksChange?(sorted)
    }

    // MARK: Sharing

    /// The images on screen, left to right as they sit on the screen. One image when a single
    /// page shows, or when the two halves of one split image do.
    var pagesOnScreenLeftToRight: [Int] { rightToLeft ? Array(currentPages.reversed()) : currentPages }

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

    /// How pages are drawn (contrast, sharpness, paper): the values being dragged in the
    /// adjustments panel while a slider moves, else the book's own, else the defaults.
    var look: PageLook { previewLook ?? savedLook }

    var savedLook: PageLook {
        PageLook(contrast: options.contrast ?? defaults.contrast, sharpness: options.sharpness ?? defaults.sharpness,
                 paperGrain: options.paperGrain ?? defaults.paperGrain, paperTint: options.paperTint ?? defaults.paperTint)
    }

    /// Slider values shown live but not saved yet (see `commitLook`).
    var previewLook: PageLook?

    /// Saves the previewed look as this book's own, for the values that changed.
    func commitLook() {
        guard let preview = previewLook else { return }
        let saved = savedLook
        change { options in
            if preview.contrast != saved.contrast { options.contrast = preview.contrast }
            if preview.sharpness != saved.sharpness { options.sharpness = preview.sharpness }
            if preview.paperGrain != saved.paperGrain { options.paperGrain = preview.paperGrain }
            if preview.paperTint != saved.paperTint { options.paperTint = preview.paperTint }
        }
        previewLook = nil
    }

    /// Set by a swipe up on the page: the reader closes.
    var closeRequested = false
    /// Set when the pager has turned back from the first page to the cover: the reader's
    /// cover takes over.
    var coverRequested = false
    /// Bumped by a tap on the back side of the first page: the pager turns back to the cover.
    private(set) var turnToCover = 0
    /// Makes the page the pager slides in before the first one: the cover, as the reader
    /// shows it. Nil when the book has no cover.
    @ObservationIgnored var makeCoverPage: (() -> UIViewController)?

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
        let look = savedLook
        resolved.contrast = look.contrast
        resolved.sharpness = look.sharpness
        resolved.paperGrain = look.paperGrain
        resolved.paperTint = look.paperTint
        return resolved
    }

    /// Changes this book's own settings, saves them and redraws.
    func change(_ edit: (inout ReaderOptions) -> Void) {
        var updated = options
        edit(&updated)
        guard updated != options else { return }
        updated.updatedAt = Date()
        let layoutChanged = Self.withoutLook(updated) != Self.withoutLook(options)
        options = updated
        onOptionsChange?(updated)
        if layoutChanged {
            relayout()
        } else {
            // Only the look changed: the page view redraws the pages it has, and the pages
            // ahead are made again with the new look.
            prefetch()
        }
    }

    /// The settings that decide which pages show where, leaving out how they are drawn.
    private static func withoutLook(_ options: ReaderOptions) -> ReaderOptions {
        var options = options
        options.contrast = nil
        options.sharpness = nil
        options.paperGrain = nil
        options.paperTint = nil
        options.updatedAt = .distantPast
        return options
    }

    /// Everything back to the defaults, the page crop too, as Book Info's Reset does (#90).
    func resetToDefaults() {
        change { options in options = ReaderOptions(updatedAt: options.updatedAt) }
    }

    /// Whether Reset to Defaults would change anything (a crop counts).
    var canReset: Bool { !options.isEmpty }

    /// Makes this book's settings the defaults for every book, and lets this one follow them.
    /// Its crop stays: a crop is the book's own and has no default.
    func useAsDefaults() {
        defaults.adopt(resolvedOptions)
        change { options in
            let crop = options.crop
            options = ReaderOptions(updatedAt: options.updatedAt)
            options.crop = crop
        }
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

    /// The crop for a page as shown, as fractions of the page (or of its half); nil for none.
    /// The crop is worked out for the whole image before it is split: each half of a double
    /// page takes the crop of its side.
    func cropRect(for page: DisplayPage) -> CGRect? {
        guard let crop = options.crop, sides.indices.contains(page.page) else { return nil }
        let rect: [Double]
        switch page.part {
        case .left: rect = crop.rect(for: .left)
        case .right: rect = crop.rect(for: .right)
        case .whole: rect = crop.rect(for: sides[page.page])
        }
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
        spreads = SpreadLayout.spreads(displayPages, twoPage: usesTwoPages) { wide.contains($0) }
        sides = SpreadLayout.pageSides(pageCount: pageCount, rightToLeft: rightToLeft) { wide.contains($0) }
        pairs = SpreadLayout.spreads(pageCount: pageCount, twoPage: true) { wide.contains($0) }
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

    /// The pages the crop editor shows, uncropped: the left and right page of the spread
    /// around the page on screen (or the two halves of an image that holds both). A side is
    /// nil when the book has no page for it nearby.
    func cropPreview() async -> (left: CGImage?, right: CGImage?, sameImage: Bool) {
        let page = currentPage
        let size = PageImageCache.screenPixelSize
        func load(_ index: Int) async -> CGImage? {
            await cache.load(page: index, size: size, from: source)?.cgImage
        }
        if widePages.contains(page), let image = await load(page) {
            return (PagePieces.cut(image, part: .left, crop: nil), PagePieces.cut(image, part: .right, crop: nil), true)
        }
        // The nearest pair of single pages, starting from the one on screen.
        let here = pairs.firstIndex { $0.contains(page) } ?? 0
        let order = pairs.indices.sorted { a, b in
            let da = abs(a - here), db = abs(b - here)
            return da != db ? da < db : a > b
        }
        if let found = order.first(where: { pairs[$0].count == 2 }) {
            let pair = pairs[found]
            let leftPage = rightToLeft ? pair[1] : pair[0]
            let rightPage = rightToLeft ? pair[0] : pair[1]
            let leftImage = await load(leftPage)
            let rightImage = await load(rightPage)
            return (leftImage, rightImage, false)
        }
        // No pairs (a book of one page, say): show this page on its side.
        let image = await load(page)
        let side = sides.indices.contains(page) ? sides[page] : .right
        return side == .left ? (image, nil, false) : (nil, image, false)
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

    /// The previous page, or the cover from the first one.
    private func back() {
        if currentSpread == 0, makeCoverPage != nil {
            turnToCover += 1
        } else {
            previous()
        }
    }
    func previous() { show(spread: currentSpread - 1) }

    func jump(toPage page: Int) {
        show(spread: SpreadLayout.spreadIndex(containing: page, in: spreads))
    }

    /// Tap zones: the outer thirds turn pages (mirrored for right-to-left), the middle shows controls.
    func handleTap(atFraction x: CGFloat) {
        if x < 0.3 {
            rightToLeft ? next() : back()
            showChrome = false
        } else if x > 0.7 {
            rightToLeft ? back() : next()
            showChrome = false
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
        let adjustments = savedLook.adjustments
        prefetchTask = Task.detached(priority: .userInitiated) {
            for page in indices {
                if Task.isCancelled { return }
                _ = await cache.load(page: page, size: size, from: source, adjustments: adjustments)
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
        adjusted.totalCostLimit = 200 * 1024 * 1024
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

    // MARK: Adjusted pages

    /// Pages with contrast, sharpness or tint applied, by page and adjustments.
    private let adjusted = NSCache<NSString, Entry>()
    private var adjusting: [String: Task<UIImage?, Never>] = [:]

    private static func key(_ page: Int, _ adjustments: PageAdjustments) -> NSString {
        "\(page)|\(adjustments.key)" as NSString
    }

    /// The page drawn with `adjustments`, if it is in memory.
    func image(for page: Int, minSize: CGFloat, adjustments: PageAdjustments) -> UIImage? {
        if adjustments.isNone { return image(for: page, minSize: minSize) }
        guard let entry = adjusted.object(forKey: Self.key(page, adjustments)), entry.size >= minSize * 0.99 else { return nil }
        return entry.image
    }

    /// The page at `size` drawn with `adjustments`: decoded as usual, then filtered once
    /// off the main thread and kept, so turning back to it is instant.
    func load(page: Int, size: CGFloat, from source: BookSource, adjustments: PageAdjustments) async -> UIImage? {
        if adjustments.isNone { return await load(page: page, size: size, from: source) }
        if let cached = image(for: page, minSize: size, adjustments: adjustments) { return cached }
        let key = Self.key(page, adjustments)
        let taskKey = "\(key)|\(Int(size))"
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = adjusting[taskKey] { return running }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                let raw = await self.load(page: page, size: size, from: source)
                var result = raw
                if let cgImage = raw?.cgImage, let filtered = PageFilter.apply(adjustments, to: cgImage, seed: page) {
                    let image = UIImage(cgImage: filtered)
                    let cost = Int(image.size.width * image.size.height * 4)
                    if let existing = self.adjusted.object(forKey: key), existing.size >= size {
                        // A larger copy is already there.
                    } else {
                        self.adjusted.setObject(Entry(image: image, size: size), forKey: key, cost: cost)
                    }
                    result = image
                }
                self.lock.withLock { self.adjusting[taskKey] = nil }
                return result
            }
            adjusting[taskKey] = task
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
