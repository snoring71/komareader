import ArchiveKit
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
        controller.view.backgroundColor = .black
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
        if version != coordinator.layoutVersion || direction != coordinator.rightToLeft {
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

        init(state: ReaderState) { self.state = state }

        func show(in controller: UIPageViewController, animated: Bool) {
            let target = state.currentSpread
            let forward = target >= displayedSpread
            // Next comes from the right in left-to-right books, from the left in manga.
            let direction: UIPageViewController.NavigationDirection = (forward != state.rightToLeft) ? .forward : .reverse
            displayedSpread = target
            layoutVersion = state.layoutVersion
            rightToLeft = state.rightToLeft
            guard state.spreads.indices.contains(target) else { return }
            let page = makeController(target)
            controller.setViewControllers([page], direction: direction, animated: animated)
            page.reportTextStatus()
        }

        private func makeController(_ spread: Int) -> SpreadViewController {
            let controller = SpreadViewController(
                spreadIndex: spread, pages: state.spreads[spread], rightToLeft: state.rightToLeft,
                fit: state.fit, source: state.source, cache: state.cache, textAnalyzer: state.textAnalyzer
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
            return controller
        }

        private func neighbour(of controller: UIViewController, step: Int) -> UIViewController? {
            guard let current = controller as? SpreadViewController else { return nil }
            let target = current.spreadIndex + (state.rightToLeft ? -step : step)
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
            guard completed, let current = pvc.viewControllers?.first as? SpreadViewController else { return }
            displayedSpread = current.spreadIndex
            state.show(spread: current.spreadIndex)
            current.selectingText = state.selectingText
            current.reportTextStatus()
        }
    }
}

/// One screen: one or two pages side by side, zoomable.
final class SpreadViewController: UIViewController, UIScrollViewDelegate {
    let spreadIndex: Int
    let pages: [Int]
    private let rightToLeft: Bool
    private let fit: ReaderState.Fit
    private let source: BookSource
    private let cache: PageImageCache
    private let textAnalyzer: PageTextAnalyzer
    var onTap: ((CGFloat) -> Void)?
    /// Reports what Live Text found on this spread, with the spread's index.
    var onTextStatus: ((Int, ReaderState.TextStatus) -> Void)?
    /// Select Text mode: find the text on the pages and let it be selected.
    var selectingText = false {
        didSet { if selectingText != oldValue, isViewLoaded { updateTextSelection() } }
    }

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var imageViews: [UIImageView] = []
    private var spinners: [UIActivityIndicatorView] = []
    private var loadTasks: [Task<Void, Never>] = []
    private var loadedSize: CGFloat = 0
    private var laidOutContentSize: CGSize = .zero
    private var textInteractions: [ImageAnalysisInteraction] = []
    /// Per slot: the image whose text is on the interaction (or being read), and what was found.
    private var analyzedImages: [UIImage?] = []
    private var slotStatus: [ReaderState.TextStatus] = []
    /// Per slot: the image showing is a smaller stand-in until the decode finishes.
    private var placeholders: [Bool] = []
    private var textTasks: [Task<Void, Never>?] = []

    init(spreadIndex: Int, pages: [Int], rightToLeft: Bool, fit: ReaderState.Fit, source: BookSource, cache: PageImageCache, textAnalyzer: PageTextAnalyzer) {
        self.spreadIndex = spreadIndex
        self.pages = pages
        self.rightToLeft = rightToLeft
        self.fit = fit
        self.source = source
        self.cache = cache
        self.textAnalyzer = textAnalyzer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTasks.forEach { $0.cancel() }
        textTasks.forEach { $0?.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
        for _ in pages {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = UIColor(white: 0.08, alpha: 1)
            contentView.addSubview(imageView)
            imageViews.append(imageView)
            let spinner = UIActivityIndicatorView(style: .large)
            spinner.color = .white
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
        }

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        view.accessibilityIdentifier = "reader-page"

        load(size: PageImageCache.screenPixelSize)
        if selectingText { updateTextSelection() }
    }

    private var screenOrder: [Int] { rightToLeft ? Array(pages.reversed()) : pages }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPages()
    }

    /// Sizes the page(s) for the fit setting, side by side, keeping each page's aspect ratio.
    /// Fit Screen shows the whole spread; Fit Width and Fit Height can run past the screen,
    /// and the spread then scrolls (down for width, sideways for height).
    private func layoutPages() {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspects = imageViews.map { view -> CGFloat in
            guard let size = view.image?.size, size.height > 0 else { return 2.0 / 3.0 }
            return size.width / size.height
        }
        let totalAspect = max(aspects.reduce(0, +), 0.01)
        let height: CGFloat
        switch fit {
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
        let y = max(0, (area.height - height) / 2)
        for (view, aspect) in zip(imageViews, aspects) {
            view.frame = CGRect(x: x, y: y, width: height * aspect, height: height).integral
            view.subviews.first?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            x += height * aspect
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
        for (slot, page) in screenOrder.enumerated() {
            if let cached = cache.image(for: page, minSize: size) {
                imageViews[slot].image = cached
                placeholders[slot] = false
                if selectingText { readText(slot: slot) }
                continue
            }
            // Until the page is decoded, show a smaller copy if there is one, or a spinner, rather than a black page.
            if imageViews[slot].image == nil {
                if let smaller = cache.image(for: page, minSize: 0) {
                    imageViews[slot].image = smaller
                    placeholders[slot] = true
                } else {
                    spinners[slot].startAnimating()
                }
            }
            let source = source, cache = cache
            loadTasks.append(Task { [weak self] in
                let image = await cache.load(page: page, size: size, from: source)
                guard let self, !Task.isCancelled else { return }
                self.spinners[slot].stopAnimating()
                guard let image else {
                    if self.selectingText, self.imageViews[slot].image == nil || self.placeholders[slot] {
                        self.slotStatus[slot] = .none
                        self.reportTextStatus()
                    }
                    return
                }
                self.imageViews[slot].image = image
                self.placeholders[slot] = false
                self.view.setNeedsLayout()
                if self.selectingText { self.readText(slot: slot) }
            })
        }
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
                if slotStatus[slot] == .searching {
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
        guard textInteractions.indices.contains(slot), let image = imageViews[slot].image else { return }
        if image === analyzedImages[slot] { return }
        // A smaller copy stands in while the page decodes; wait for the real one.
        if placeholders[slot] {
            slotStatus[slot] = .searching
            reportTextStatus()
            return
        }
        analyzedImages[slot] = image
        slotStatus[slot] = .searching
        reportTextStatus()
        let page = screenOrder[slot], analyzer = textAnalyzer
        textTasks[slot]?.cancel()
        textTasks[slot] = Task { [weak self] in
            let analysis = await analyzer.analysis(page: page, image: image)
            guard let self, !Task.isCancelled, self.selectingText, self.imageViews[slot].image === image else { return }
            let interaction = self.textInteractions[slot]
            interaction.analysis = analysis
            interaction.selectableItemsHighlighted = analysis != nil
            let hasText = analysis?.hasResults(for: .text) ?? false
            self.slotStatus[slot] = hasText ? .found : .none
            self.reportTextStatus()
        }
    }

    /// Tells the reader what was found across this spread's pages.
    func reportTextStatus() {
        let status: ReaderState.TextStatus
        if !selectingText || slotStatus.isEmpty {
            status = .idle
        } else if slotStatus.contains(.found) {
            status = .found
        } else if slotStatus.contains(.searching) || slotStatus.contains(.idle) {
            status = .searching
        } else {
            status = .none
        }
        onTextStatus?(spreadIndex, status)
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
