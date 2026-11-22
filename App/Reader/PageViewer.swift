import ArchiveKit
import ComicCore
import SwiftUI
import UIKit
import VisionKit

/// Horizontal paging with real UIKit physics, hosted in SwiftUI.
struct PageViewer: UIViewControllerRepresentable {
    let state: ReaderState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll, navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]
        )
        controller.view.backgroundColor = state.background.uiColor ?? .black
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.show(in: controller, animated: false)
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        // Read the observed values here so SwiftUI updates us when they change.
        let spread = state.currentSpread
        let version = state.layoutVersion
        let direction = state.rightToLeft
        let selectingText = state.selectingText
        if selectingText != coordinator.selectingText {
            coordinator.selectingText = selectingText
            (controller.viewControllers?.first as? SpreadViewController)?.selectingText = selectingText
        }
        let textRetry = state.textRetry
        if textRetry != coordinator.textRetry {
            coordinator.textRetry = textRetry
            (controller.viewControllers?.first as? SpreadViewController)?.retryText()
        }
        let turnToCover = state.turnToCover
        if turnToCover != coordinator.turnToCover {
            coordinator.turnToCover = turnToCover
            coordinator.showCoverPage(in: controller)
        }
        let turnToEnd = state.turnToEnd
        if turnToEnd != coordinator.turnToEnd {
            coordinator.turnToEnd = turnToEnd
            coordinator.showEndPage(in: controller)
        }
        let backFromEnd = state.backFromEnd
        if backFromEnd != coordinator.backFromEnd {
            coordinator.backFromEnd = backFromEnd
            coordinator.leaveEndPage(in: controller)
        }
        let look = state.look
        if look != coordinator.look {
            coordinator.look = look
            coordinator.applyLook()
        }
        if version != coordinator.layoutVersion || direction != coordinator.rightToLeft {
            if let color = state.background.uiColor { controller.view.backgroundColor = color }
            coordinator.show(in: controller, animated: false)
        } else if spread != coordinator.displayedSpread {
            coordinator.show(in: controller, animated: abs(spread - coordinator.displayedSpread) == 1)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let state: ReaderState
        var displayedSpread = -1
        var layoutVersion = -1
        var rightToLeft = false
        var selectingText = false
        var textRetry = 0
        var look = PageLook()
        var turnToCover = 0
        var turnToEnd = 0
        var backFromEnd = 0
        private weak var pageController: UIPageViewController?
        /// Every spread made and still alive (on screen, or kept ready beside it), so a new
        /// look reaches the neighbours too.
        private let live = NSHashTable<SpreadViewController>.weakObjects()

        init(state: ReaderState) {
            self.state = state
            self.look = state.look
        }

        /// A tap back from the first page: the cover turns in like a page, as a swipe does.
        func showCoverPage(in controller: UIPageViewController) {
            guard let cover = state.makeCoverPage?() else { return }
            cover.view.accessibilityIdentifier = "reader-cover-page"
            // Back comes from the left in left-to-right books, from the right in manga.
            let direction: UIPageViewController.NavigationDirection = state.rightToLeft ? .forward : .reverse
            controller.setViewControllers([CoverPageController(cover)], direction: direction, animated: true) { [weak self, weak controller] finished in
                guard let self, let controller, finished else { return }
                self.coverPageShown(in: controller)
            }
        }

        /// A tap forward on the last page: the page offering the next book turns in (#83).
        func showEndPage(in controller: UIPageViewController) {
            guard let end = state.makeEndPage?() else { return }
            let direction: UIPageViewController.NavigationDirection = state.rightToLeft ? .reverse : .forward
            state.onEndPage = true
            controller.setViewControllers([EndPageController(end)], direction: direction, animated: true) { [weak self] finished in
                if finished { self?.state.showChrome = false }
            }
        }

        /// Not Now on that page: back to the last page.
        func leaveEndPage(in controller: UIPageViewController) {
            let last = state.spreads.count - 1
            state.onEndPage = false
            guard controller.viewControllers?.first is EndPageController, state.spreads.indices.contains(last) else { return }
            let direction: UIPageViewController.NavigationDirection = state.rightToLeft ? .forward : .reverse
            // The last screen of the layout now on screen, which a turn of the iPad may have
            // renumbered while the next-book page showed.
            displayedSpread = last
            // Not during this SwiftUI update: the reader's state follows a moment later.
            DispatchQueue.main.async { [state] in state.show(spread: last) }
            let page = makeController(last)
            controller.setViewControllers([page], direction: direction, animated: true)
            followBackground(of: page)
            becameCurrent(page)
        }

        /// The cover page is on screen: the reader's cover takes over (it looks the same, and
        /// appears at once), then the first page goes back underneath it.
        private func coverPageShown(in controller: UIPageViewController) {
            state.coverRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.show(in: controller, animated: false)
            }
        }

        /// Redraws the pages already made with the current look.
        func applyLook() {
            for page in live.allObjects { page.look = look }
        }

        func show(in controller: UIPageViewController, animated: Bool) {
            let target = state.currentSpread
            let forward = target >= displayedSpread
            // Next comes from the right in left-to-right books, from the left in manga.
            let direction: UIPageViewController.NavigationDirection = (forward != state.rightToLeft) ? .forward : .reverse
            // The next-book page stays through a new layout: turning the iPad renumbers the
            // screens (landscape pairs pages; split mode halves the last image in portrait).
            let onEndPage = state.onEndPage && controller.viewControllers?.first is EndPageController
            displayedSpread = target
            layoutVersion = state.layoutVersion
            rightToLeft = state.rightToLeft
            pageController = controller
            // The page offering the next book stays through a turn of the iPad (a new layout):
            // its card lays itself out again for the new size (#83).
            if onEndPage { return }
            guard state.spreads.indices.contains(target) else { return }
            let page = makeController(target)
            controller.setViewControllers([page], direction: direction, animated: animated)
            followBackground(of: page)
            becameCurrent(page)
        }

        /// Copy All and the Select Text bar follow the spread on screen.
        private func becameCurrent(_ page: SpreadViewController) {
            page.selectingText = state.selectingText
            state.currentTranscript = { [weak page] in page?.transcript ?? "" }
            page.reportTextStatus()
        }

        private func makeController(_ spread: Int) -> SpreadViewController {
            var pages = state.spreads[spread]
            // Both halves of one image on the same screen: show the image itself, so there is
            // no seam (or binding shadow) down the middle of a drawn spread.
            if pages.count == 2, pages[0].page == pages[1].page, pages[0].isHalf, pages[1].isHalf {
                pages = [DisplayPage(page: pages[0].page)]
            }
            let pieces = pages.map { page -> SpreadViewController.Piece in
                let crop = state.cropRect(for: page)
                // An image holding two pages: where they meet, for the binding shadow.
                var fold: CGFloat?
                if page.part == .whole, state.sides.indices.contains(page.page), state.sides[page.page] == .both {
                    let shown = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    fold = (0.5 - shown.minX) / max(shown.width, 0.01)
                }
                return SpreadViewController.Piece(page: page, crop: crop, fold: fold)
            }
            let style = SpreadViewController.Style(
                fit: state.fit, background: state.background, bindingShadow: CGFloat(state.bindingShadow),
                autoTrim: state.autoTrim
            )
            let controller = SpreadViewController(
                spreadIndex: spread, pieces: pieces, rightToLeft: state.rightToLeft,
                style: style, source: state.source, cache: state.cache, edgeColors: state.edgeColors,
                textAnalyzer: state.textAnalyzer
            )
            controller.onTap = { [weak self] fraction in self?.state.handleTap(atFraction: fraction) }
            // Only the spread on screen speaks for the screen; neighbours read their text quietly.
            controller.onTextStatus = { [weak self] index, status in
                // Later, since this can run while SwiftUI is updating the page view.
                Task { @MainActor [weak self] in
                    guard let self, index == self.state.currentSpread, self.state.selectingText else { return }
                    if self.state.textStatus != status { self.state.textStatus = status }
                }
            }
            controller.selectingText = state.selectingText
            controller.look = look
            controller.onSwipeUp = { [weak self] in self?.state.closeRequested = true }
            live.add(controller)
            controller.onBackgroundChange = { [weak self, weak controller] in
                guard let self, let controller else { return }
                if controller.spreadIndex == self.displayedSpread { self.followBackground(of: controller) }
            }
            return controller
        }

        /// With Match Page, the gap between pages while swiping takes the colour of the page on screen.
        private func followBackground(of page: SpreadViewController) {
            guard state.background == .dynamic, let color = page.currentBackground else { return }
            UIView.animate(withDuration: 0.25) { self.pageController?.view.backgroundColor = color }
        }

        private func neighbour(of controller: UIViewController, step: Int) -> UIViewController? {
            // Back from the next-book page is the last page; there is nothing beyond it.
            if controller is EndPageController {
                let last = state.spreads.count - 1
                guard (state.rightToLeft ? -step : step) < 0, state.spreads.indices.contains(last) else { return nil }
                return makeController(last)
            }
            guard let current = controller as? SpreadViewController else { return nil }
            let target = current.spreadIndex + (state.rightToLeft ? -step : step)
            // On from the last page: the next book, when there is one (#83).
            if target == state.spreads.count, let end = state.makeEndPage?() {
                return EndPageController(end)
            }
            // Back from the first page: the cover slides in, like turning back to it in a book.
            if target == -1, let cover = state.makeCoverPage?() {
                cover.view.accessibilityIdentifier = "reader-cover-page"
                return CoverPageController(cover)
            }
            guard state.spreads.indices.contains(target) else { return nil }
            return makeController(target)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            neighbour(of: vc, step: -1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            neighbour(of: vc, step: 1)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            // A neighbour made before Select Text was switched on catches up here.
            for case let page as SpreadViewController in pending { page.selectingText = state.selectingText }
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed else { return }
            if pvc.viewControllers?.first is CoverPageController {
                coverPageShown(in: pvc)
                return
            }
            if pvc.viewControllers?.first is EndPageController {
                state.onEndPage = true
                if state.showChrome { state.showChrome = false }
                return
            }
            guard let current = pvc.viewControllers?.first as? SpreadViewController else { return }
            state.onEndPage = false
            displayedSpread = current.spreadIndex
            state.show(spread: current.spreadIndex)
            // Turning the page by swiping puts the controls away.
            if state.showChrome { state.showChrome = false }
            followBackground(of: current)
            becameCurrent(current)
        }
    }
}

/// The cover as a page in the pager, before the first page, holding the reader's cover view.
final class CoverPageController: UIViewController {
    private let content: UIViewController

    init(_ content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }
}

/// The page after the last one, offering the next book (#83), holding `NextBookPage`.
final class EndPageController: UIViewController {
    private let content: UIViewController

    init(_ content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "reader-end-page"
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }
}

/// One screen: one or two pages side by side, zoomable.
final class SpreadViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// One page on this screen: an image (or half of one) and the crop to show of it.
    struct Piece {
        let page: DisplayPage
        let crop: CGRect?
        /// For an image holding two pages, where they meet, as a fraction across the image shown.
        let fold: CGFloat?
        var colorKey: NSString { "\(page)|\(crop.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-")" as NSString }
    }

    struct Style {
        let fit: ReaderState.Fit
        let background: ReaderOptions.Background
        /// 0 for none, up to 1.
        let bindingShadow: CGFloat
        /// Trim each page's plain margins as it loads (#116), where no crop is set.
        var autoTrim = false
    }

    let spreadIndex: Int
    let pieces: [Piece]
    private let rightToLeft: Bool
    private let style: Style
    private let source: BookSource
    private let cache: PageImageCache
    private let edgeColors: NSCache<NSString, UIColor>
    var onTap: ((CGFloat) -> Void)?
    private let textAnalyzer: PageTextAnalyzer
    /// Reports what Live Text found on this spread, with the spread's index.
    var onTextStatus: ((Int, ReaderState.TextStatus) -> Void)?
    /// Select Text mode: find the text on the pages and let it be selected.
    var selectingText = false {
        didSet { if selectingText != oldValue, isViewLoaded { updateTextSelection() } }
    }
    /// Contrast, sharpness and paper. Changing it redraws the pages showing.
    var look = PageLook() {
        didSet {
            guard look != oldValue, isViewLoaded else { return }
            if look.adjustments != oldValue.adjustments { refilter() }
            if look.sharperScaling != oldValue.sharperScaling {
                for slot in imageViews.indices { if let cut = cutImages[slot] { imageViews[slot].image = cut } }
                scaledFor = Array(repeating: nil, count: imageViews.count)
                view.setNeedsLayout()
            }
        }
    }
    /// Called when the page has been swiped up past the point of closing the book.
    var onSwipeUp: (() -> Void)?
    /// Called when a Match Page background has been worked out.
    var onBackgroundChange: (() -> Void)?
    private(set) var currentBackground: UIColor?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var imageViews: [UIImageView] = []
    /// Per slot: the decoded (and filtered) image before it is cut to its half and crop.
    private var uncutImages: [UIImage?] = []
    /// Per slot: the image cut to what the page shows, before any Lanczos resize.
    private var cutImages: [UIImage?] = []
    /// Per slot: the measured margin trim, when Auto Trim is on (nil: none or not yet).
    private var trims: [CGRect?] = []
    /// Per slot: the size in pixels the image on screen was resized to, so it is done once.
    private var scaledFor: [CGSize?] = []
    private var scaleTasks: [Task<Void, Never>?] = []
    private var lookTask: Task<Void, Never>?
    /// The look changed again while the pages were being redrawn.
    private var lookPending = false
    private var swipeToClose: UIPanGestureRecognizer?
    private var spinners: [UIActivityIndicatorView] = []
    private var bindingShadow: BindingShadowView?
    private var loadTasks: [Task<Void, Never>] = []
    private var colorTask: Task<Void, Never>?
    private var loadedSize: CGFloat = 0
    private var laidOutContentSize: CGSize = .zero
    private var textInteractions: [ImageAnalysisInteraction] = []
    /// Per slot: the image whose text is on the interaction (or being read), and what was found.
    private var analyzedImages: [UIImage?] = []
    private var slotStatus: [ReaderState.TextStatus] = []
    /// Per slot: the image showing is a smaller stand-in until the decode finishes.
    private var placeholders: [Bool] = []
    private var textTasks: [Task<Void, Never>?] = []
    /// Per slot: how many times Try Again has asked for this page, which picks the read sizes.
    private var readAttempts: [Int] = []
    /// Sizes to read a page at (longest side in pixels; nil is the image on screen). Small text
    /// beside furigana reads better sharp, but Live Text sometimes finds nothing on a page at one
    /// size and everything at another, so an empty read tries the next size, and Try Again
    /// starts one further along.
    private static let readSizes: [CGFloat?] = [4096, nil, 2048]

    init(spreadIndex: Int, pieces: [Piece], rightToLeft: Bool, style: Style, source: BookSource,
         cache: PageImageCache, edgeColors: NSCache<NSString, UIColor>, textAnalyzer: PageTextAnalyzer) {
        self.spreadIndex = spreadIndex
        self.pieces = pieces
        self.rightToLeft = rightToLeft
        self.style = style
        self.source = source
        self.cache = cache
        self.edgeColors = edgeColors
        self.textAnalyzer = textAnalyzer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTasks.forEach { $0.cancel() }
        colorTask?.cancel()
        lookTask?.cancel()
        textTasks.forEach { $0?.cancel() }
        scaleTasks.forEach { $0?.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let background = style.background.uiColor ?? cachedEdgeColor() ?? .black
        currentBackground = style.background == .dynamic ? cachedEdgeColor() : background
        view.backgroundColor = background
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // Pages in screen order: in manga the first page is on the right.
        let light = background.isLight
        for _ in pieces {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = light ? UIColor(white: 0, alpha: 0.06) : UIColor(white: 1, alpha: 0.06)
            contentView.addSubview(imageView)
            imageViews.append(imageView)
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = light ? .darkGray : .white
            spinner.hidesWhenStopped = true
            spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
            imageView.addSubview(spinner)
            spinners.append(spinner)
            if PageTextAnalyzer.isSupported {
                // Live Text, idle until Select Text is on. Touches on the page still reach the
                // scroll view's taps and zoom, so the image view can take them.
                let interaction = ImageAnalysisInteraction()
                interaction.preferredInteractionTypes = []
                interaction.isSupplementaryInterfaceHidden = true
                imageView.isUserInteractionEnabled = true
                imageView.addInteraction(interaction)
                textInteractions.append(interaction)
            }
            analyzedImages.append(nil)
            slotStatus.append(.idle)
            placeholders.append(false)
            textTasks.append(nil)
            readAttempts.append(0)
            uncutImages.append(nil)
            cutImages.append(nil)
            trims.append(nil)
            scaledFor.append(nil)
            scaleTasks.append(nil)
        }
        let isSpread = pieces.count == 2 || (pieces.count == 1 && pieces[0].fold.map { $0 > 0.1 && $0 < 0.9 } == true)
        if isSpread, style.bindingShadow > 0 {
            let shadow = BindingShadowView(strength: style.bindingShadow)
            contentView.addSubview(shadow)
            bindingShadow = shadow
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(handleSwipeUp(_:)))
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
        swipeToClose = swipe
        view.accessibilityIdentifier = "reader-page"

        load(size: PageImageCache.screenPixelSize)
        if selectingText { updateTextSelection() }
    }

    private var screenOrder: [Piece] { rightToLeft ? Array(pieces.reversed()) : pieces }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
        rescaleIfNeeded()
    }

    /// Sizes the page(s) for the fit setting, side by side, keeping each page's aspect ratio.
    /// Fit Screen shows the whole spread; Fit Width and Fit Height can run past the screen,
    /// and the spread then scrolls (down for width, sideways for height).
    private func layoutPages() {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspects = imageViews.indices.map { slot -> CGFloat in
            // The cut image, not a resized copy, so rounding in the resize never moves the layout.
            guard let size = (cutImages[slot] ?? imageViews[slot].image)?.size, size.height > 0 else { return 2.0 / 3.0 }
            return size.width / size.height
        }
        let totalAspect = max(aspects.reduce(0, +), 0.01)
        let height: CGFloat
        switch style.fit {
        case .screen: height = min(bounds.height, bounds.width / totalAspect)
        case .width: height = bounds.width / totalAspect
        case .height: height = bounds.height
        }
        let content = CGSize(width: max(bounds.width, (height * totalAspect).rounded()), height: max(bounds.height, height.rounded()))
        if scrollView.zoomScale == 1 {
            contentView.frame = CGRect(origin: .zero, size: content)
            scrollView.contentSize = content
            if content != laidOutContentSize {
                laidOutContentSize = content
                scrollToStart()
            }
        }
        let area = contentView.bounds.size
        var x = (area.width - height * totalAspect) / 2
        let y = max(0, (area.height - height) / 2).rounded()
        for (view, aspect) in zip(imageViews, aspects) {
            // Round the edges, not each frame, so neighbouring pages meet without a gap.
            let minX = x.rounded(), maxX = (x + height * aspect).rounded()
            view.frame = CGRect(x: minX, y: y, width: maxX - minX, height: height.rounded())
            view.subviews.first?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            x += height * aspect
        }
        // Where the two pages meet, darkened a little like the fold of a printed book.
        if let bindingShadow {
            if imageViews.count == 2 {
                let left = imageViews[0].frame, right = imageViews[1].frame
                let width = (min(left.width, right.width) * 0.12).rounded()
                let top = min(left.minY, right.minY), bottom = max(left.maxY, right.maxY)
                bindingShadow.frame = CGRect(x: left.maxX - width / 2, y: top, width: width, height: bottom - top)
            } else if let frame = imageViews.first?.frame, let fold = pieces.first?.fold {
                let seam = frame.minX + fold * frame.width
                let width = (min(fold, 1 - fold) * frame.width * 0.12).rounded()
                bindingShadow.frame = CGRect(x: seam - width / 2, y: frame.minY, width: width, height: frame.height)
            }
        }
    }

    /// Where reading starts: the top, and the first page's side (the right in manga).
    private func scrollToStart() {
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.contentOffset = CGPoint(x: rightToLeft ? maxX : 0, y: 0)
    }

    private func load(size: CGFloat) {
        guard size > loadedSize else { return }
        loadedSize = size
        let adjustments = look.adjustments
        for (slot, piece) in screenOrder.enumerated() {
            let page = piece.page.page
            if trimsSlot(slot), trims[slot] == nil, let known = cache.knownTrim(for: page) { setTrim(known, slot: slot) }
            if let cached = cache.image(for: page, minSize: size, adjustments: adjustments),
               !trimsSlot(slot) || cache.knownTrim(for: page) != nil {
                display(cached, in: slot)
                placeholders[slot] = false
                if selectingText { readText(slot: slot) }
                continue
            }
            // Until the page is decoded, show a smaller copy if there is one, or a spinner, rather than a black page.
            if imageViews[slot].image == nil {
                if let smaller = cache.image(for: page, minSize: 0) {
                    display(smaller, in: slot)
                    placeholders[slot] = true
                } else {
                    spinners[slot].startAnimating()
                }
            }
            let source = source, cache = cache
            loadTasks.append(Task { [weak self] in
                let image = await cache.load(page: page, size: size, from: source, adjustments: adjustments)
                guard let self, !Task.isCancelled else { return }
                self.spinners[slot].stopAnimating()
                // Drawn with a look that has changed since: the redraw for the new one shows it.
                if adjustments != self.look.adjustments, self.imageViews[slot].image != nil, !self.placeholders[slot] { return }
                guard let image else {
                    if self.selectingText, self.imageViews[slot].image == nil || self.placeholders[slot] {
                        self.slotStatus[slot] = .none
                        self.reportTextStatus()
                    }
                    return
                }
                if self.trimsSlot(slot), self.trims[slot] == nil {
                    let trim = await cache.trim(for: page, from: source)
                    guard !Task.isCancelled else { return }
                    self.setTrim(trim, slot: slot)
                }
                self.display(image, in: slot)
                self.placeholders[slot] = false
                self.view.setNeedsLayout()
                if self.selectingText { self.readText(slot: slot) }
            })
        }
    }

    // MARK: Look

    /// Redraws the pages showing with the current adjustments. While a slider is dragged
    /// this is asked for faster than pages can be filtered, so one redraw runs at a time and
    /// the latest look follows it.
    private func refilter() {
        if lookTask != nil {
            lookPending = true
            return
        }
        let adjustments = look.adjustments, size = loadedSize
        guard size > 0 else { return }
        lookTask = Task { [weak self] in
            guard let self else { return }
            for (slot, piece) in self.screenOrder.enumerated() {
                let image = await self.cache.load(page: piece.page.page, size: size, from: self.source, adjustments: adjustments)
                if Task.isCancelled { return }
                if let image, adjustments == self.look.adjustments || self.lookPending {
                    self.display(image, in: slot)
                    self.placeholders[slot] = false
                }
            }
            self.lookTask = nil
            if self.lookPending {
                self.lookPending = false
                self.refilter()
            } else if self.selectingText {
                for slot in self.imageViews.indices { self.readText(slot: slot) }
            }
        }
    }

    // MARK: Swipe up to close

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let swipe = swipeToClose, gestureRecognizer === swipe else { return true }
        // Zoomed in, a drag moves around the page; selecting text, it selects.
        guard !selectingText, scrollView.zoomScale <= 1.01 else { return false }
        let velocity = swipe.velocity(in: view)
        guard velocity.y < 0, abs(velocity.y) > abs(velocity.x) * 1.5 else { return false }
        // A page taller than the screen (Fit Width) scrolls first; at its bottom, a swipe up closes.
        let maxY = scrollView.contentSize.height - scrollView.bounds.height
        return maxY <= 1 || scrollView.contentOffset.y >= maxY - 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === swipeToClose
    }

    @objc private func handleSwipeUp(_ gesture: UIPanGestureRecognizer) {
        let lift = min(0, gesture.translation(in: view).y)
        let progress = min(1, -lift / 320)
        switch gesture.state {
        case .began:
            // Stop the page from also sliding sideways or scrolling under the finger.
            for scroller in enclosingScrollViews() {
                scroller.panGestureRecognizer.isEnabled = false
                scroller.panGestureRecognizer.isEnabled = true
            }
        case .changed:
            let scale = 1 - 0.08 * progress
            view.transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: scale, y: scale)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if lift < -140 || (velocity < -900 && lift < -30) {
                let distance = view.bounds.height * 0.6
                UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
                    self.view.transform = CGAffineTransform(translationX: 0, y: -distance).scaledBy(x: 0.85, y: 0.85)
                    self.view.alpha = 0
                }
                onSwipeUp?()
            } else {
                springBack()
            }
        default:
            springBack()
        }
    }

    private func springBack() {
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.view.transform = .identity
            self.view.alpha = 1
        }
    }

    /// The page's own scroll view and the pager's, which both take drags.
    private func enclosingScrollViews() -> [UIScrollView] {
        var found: [UIScrollView] = [scrollView]
        var next = view.superview
        while let current = next {
            if let scroller = current as? UIScrollView { found.append(scroller) }
            next = current.superview
        }
        return found
    }

    // MARK: Select Text

    private func updateTextSelection() {
        guard !textInteractions.isEmpty else { return }
        for slot in textInteractions.indices {
            let interaction = textInteractions[slot]
            if selectingText {
                interaction.preferredInteractionTypes = .automaticTextOnly
                interaction.selectableItemsHighlighted = interaction.analysis != nil
                readText(slot: slot)
            } else {
                textTasks[slot]?.cancel()
                textTasks[slot] = nil
                interaction.selectableItemsHighlighted = false
                interaction.preferredInteractionTypes = []
                if slotStatus[slot] == .searching || slotStatus[slot] == .failed {
                    // Unfinished: read it again next time.
                    analyzedImages[slot] = nil
                    slotStatus[slot] = .idle
                }
            }
        }
        reportTextStatus()
    }

    /// Reads the text on one page, once its image is the full screen-size decode.
    private func readText(slot: Int) {
        guard textInteractions.indices.contains(slot), let shown = imageViews[slot].image else { return }
        if shown === analyzedImages[slot] { return }
        // A smaller copy stands in while the page decodes; wait for the real one.
        if placeholders[slot] {
            slotStatus[slot] = .searching
            reportTextStatus()
            return
        }
        analyzedImages[slot] = shown
        slotStatus[slot] = .searching
        reportTextStatus()
        let piece = screenOrder[slot], analyzer = textAnalyzer, source = source, crop = shownCrop(for: slot)
        let sizes = Self.readSizes.indices.map { Self.readSizes[($0 + readAttempts[slot]) % Self.readSizes.count] }
        textTasks[slot]?.cancel()
        textTasks[slot] = Task { [weak self] in
            var result: VisionKit.ImageAnalysis?
            for size in sizes.prefix(2) {
                let image: UIImage?
                if let size {
                    image = await Task.detached(priority: .userInitiated) {
                        guard let full = try? await source.image(at: piece.page.page, maxPixelSize: size) else { return nil }
                        let cut = piece.page.isHalf || crop != nil ? PagePieces.cut(full, part: piece.page.part, crop: crop) : full
                        return UIImage(cgImage: cut)
                    }.value
                } else {
                    image = shown
                }
                if Task.isCancelled { return }
                guard let image else { continue }
                let key = "\(piece.colorKey)|\(size.map { Int($0) } ?? 0)"
                guard let analysis = await analyzer.analysis(key: key, image: image) else { continue }
                if result == nil || analysis.hasResults(for: .text) { result = analysis }
                if analysis.hasResults(for: .text) { break }
            }
            guard let self, !Task.isCancelled, self.selectingText, self.imageViews[slot].image === shown else { return }
            // The read may come from a sharper copy than the one on screen; Live Text places its
            // text by position within the image, so it lines up all the same.
            let interaction = self.textInteractions[slot]
            interaction.analysis = result
            interaction.selectableItemsHighlighted = result != nil
            if let result {
                self.slotStatus[slot] = result.hasResults(for: .text) ? .found : .none
            } else {
                self.slotStatus[slot] = .failed
            }
            self.reportTextStatus()
        }
        // A safety net: the analyzer gives up on a stuck read itself, but pages queue one at a
        // time, so allow for a few ahead of this one.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.selectingText, self.analyzedImages[slot] === shown, self.slotStatus[slot] == .searching else { return }
            self.slotStatus[slot] = .failed
            self.reportTextStatus()
        }
    }

    /// Reads again the pages where nothing was found (or the read failed), at other sizes.
    func retryText() {
        guard selectingText else { return }
        for slot in slotStatus.indices where slotStatus[slot] == .failed || slotStatus[slot] == .none {
            readAttempts[slot] += 1
            analyzedImages[slot] = nil
            readText(slot: slot)
        }
        reportTextStatus()
    }

    /// Tells the reader what was found across this spread's pages. A page that couldn't be
    /// read counts even when the other page has text, so a missed page is never silent.
    func reportTextStatus() {
        let status: ReaderState.TextStatus
        if !selectingText || slotStatus.isEmpty {
            status = .idle
        } else if slotStatus.contains(.searching) || slotStatus.contains(.idle) {
            status = .searching
        } else if slotStatus.contains(.failed) {
            status = .failed
        } else if slotStatus.contains(.found) {
            // Text on one page and none on the other is worth a second look.
            status = slotStatus.contains(.none) ? .partial : .found
        } else {
            status = .none
        }
        onTextStatus?(spreadIndex, status)
    }

    /// The text found on this spread's pages, in reading order.
    var transcript: String {
        let readingOrder = rightToLeft ? Array(textInteractions.reversed()) : textInteractions
        return readingOrder.compactMap { $0.analysis?.transcript }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Puts a decoded image in its slot, cut to the half and crop this page shows.
    private func display(_ image: UIImage, in slot: Int) {
        uncutImages[slot] = image
        cut(slot)
        imageViews[slot].backgroundColor = .clear
        if style.background == .dynamic { matchBackground() }
    }

    /// Cuts the slot's decoded image to its half and crop, and shows it.
    private func cut(_ slot: Int) {
        guard let image = uncutImages[slot] else { return }
        let piece = screenOrder[slot]
        let crop = shownCrop(for: slot)
        let shown: UIImage
        if let cgImage = image.cgImage, piece.page.isHalf || crop != nil {
            shown = UIImage(cgImage: PagePieces.cut(cgImage, part: piece.page.part, crop: crop))
        } else {
            shown = image
        }
        cutImages[slot] = shown
        scaledFor[slot] = nil
        scaleTasks[slot]?.cancel()
        imageViews[slot].image = shown
        view.setNeedsLayout()
    }

    // MARK: Auto Trim (#116)

    /// Whether this slot's page is trimmed automatically: Auto Trim is on, the book has no
    /// crop of its own, and the page is a whole image (not half of a double page, nor a
    /// double page shown whole, whose fold would move).
    private func trimsSlot(_ slot: Int) -> Bool {
        let piece = screenOrder[slot]
        return style.autoTrim && piece.crop == nil && piece.page.part == .whole && piece.fold == nil
    }

    private func setTrim(_ trim: CGRect?, slot: Int) {
        // `.zero` marks "measured, nothing to trim", so it is not measured again.
        trims[slot] = trim ?? .zero
        // Two pages side by side keep the same top and bottom, so they still line up.
        if trims.count == 2 { for other in trims.indices where other != slot && uncutImages[other] != nil { cut(other) } }
    }

    /// The crop this slot shows: the book's own, else its trim, with two trimmed pages
    /// sharing the smaller top and bottom trim.
    private func shownCrop(for slot: Int) -> CGRect? {
        let piece = screenOrder[slot]
        if let crop = piece.crop { return crop }
        guard trimsSlot(slot), var trim = trims[slot], trim != .zero else { return nil }
        if trims.count == 2 {
            let other = trims[1 - slot]
            if trimsSlot(1 - slot), let other {
                let otherRect = other == .zero ? CGRect(x: 0, y: 0, width: 1, height: 1) : other
                let top = min(trim.minY, otherRect.minY), bottom = max(trim.maxY, otherRect.maxY)
                trim = CGRect(x: trim.minX, y: top, width: trim.width, height: bottom - top)
            } else {
                // The other page is not trimmed (or not yet measured): trim the sides only.
                trim = CGRect(x: trim.minX, y: 0, width: trim.width, height: 1)
            }
        }
        return trim
    }

    // MARK: Sharper scaling (#120)

    /// With Sharper Scaling on, resizes each page to exactly its size on screen with Lanczos
    /// resampling, once per size. Skipped while zoomed (the sharper zoom decode shows then)
    /// and while selecting text (Live Text holds on to the image it read).
    private func rescaleIfNeeded() {
        guard look.sharperScaling, scrollView.zoomScale <= 1.01, !selectingText else { return }
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        for slot in imageViews.indices {
            guard !placeholders[slot], let cut = cutImages[slot], let cgImage = cut.cgImage else { continue }
            let frame = imageViews[slot].bounds.size
            let target = CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
            guard target.width >= 8, target.height >= 8, scaledFor[slot] != target else { continue }
            scaledFor[slot] = target
            // Close enough already: nothing to gain.
            if abs(CGFloat(cgImage.height) - target.height) / target.height < 0.03 { continue }
            scaleTasks[slot]?.cancel()
            scaleTasks[slot] = Task { [weak self] in
                let scaled = await Task.detached(priority: .userInitiated) { PageFilter.lanczos(cgImage, to: target) }.value
                guard let self, !Task.isCancelled, let scaled, self.cutImages[slot] === cut,
                      self.look.sharperScaling, !self.selectingText else { return }
                self.imageViews[slot].image = UIImage(cgImage: scaled, scale: scale, orientation: .up)
            }
        }
    }

    // MARK: Match Page background

    private func cachedEdgeColor() -> UIColor? {
        let colors = pieces.compactMap { edgeColors.object(forKey: $0.colorKey) }
        guard colors.count == pieces.count, !colors.isEmpty else { return nil }
        return Self.average(colors)
    }

    /// Works out the colour around the edges of the page(s) on screen, off the main thread.
    private func matchBackground() {
        if let cached = cachedEdgeColor() {
            apply(background: cached)
            return
        }
        let shown = screenOrder.enumerated().compactMap { slot, piece -> (NSString, CGImage)? in
            guard let image = imageViews[slot].image?.cgImage else { return nil }
            return (piece.colorKey, image)
        }
        guard shown.count == pieces.count else { return }
        colorTask?.cancel()
        let edgeColors = edgeColors
        colorTask = Task { [weak self] in
            let colors = await Task.detached(priority: .userInitiated) { () -> [(NSString, UIColor)] in
                shown.compactMap { key, image in
                    ImageAnalysis.edgeColor(of: image).map { (key, UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)) }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            for (key, color) in colors { edgeColors.setObject(color, forKey: key) }
            if let color = self.cachedEdgeColor() { self.apply(background: color) }
        }
    }

    private func apply(background color: UIColor) {
        guard currentBackground != color else { return }
        let first = currentBackground == nil
        currentBackground = color
        UIView.animate(withDuration: first ? 0 : 0.25) { self.view.backgroundColor = color }
        onBackgroundChange?()
    }

    private static func average(_ colors: [UIColor]) -> UIColor {
        var total = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))
        for color in colors {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            total.r += r; total.g += g; total.b += b
        }
        let n = CGFloat(max(colors.count, 1))
        return UIColor(red: total.r / n, green: total.g / n, blue: total.b / n, alpha: 1)
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Decode sharper pages once zoomed past screen size.
        if scale > 1.4 { load(size: min(PageImageCache.screenPixelSize * min(scale, 3), 8000)) }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: contentView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard scrollView.zoomScale <= 1.01 else {
            onTap?(0.5) // When zoomed in, a tap only toggles the controls.
            return
        }
        onTap?(gesture.location(in: view).x / max(view.bounds.width, 1))
    }
}

/// A soft shadow down the middle of a two-page spread, darkest where the pages meet.
final class BindingShadowView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    init(strength: CGFloat) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        // Faint over most of its width and only darkening close to the fold, like the
        // shading in a scanned book (even Strong is only about an eighth black right at the fold).
        let peak = min(1, strength) * 0.14
        let alphas: [CGFloat] = [0, 0.04, 0.14, 0.4, 0.75, 1, 0.75, 0.4, 0.14, 0.04, 0]
        gradient.colors = alphas.map { UIColor.black.withAlphaComponent($0 * peak).cgColor }
        gradient.locations = [0, 0.2, 0.33, 0.42, 0.47, 0.5, 0.53, 0.58, 0.67, 0.8, 1]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
