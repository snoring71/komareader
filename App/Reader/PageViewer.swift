import ArchiveKit
import ComicCore
import SwiftUI
import UIKit

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
        private weak var pageController: UIPageViewController?

        init(state: ReaderState) { self.state = state }

        func show(in controller: UIPageViewController, animated: Bool) {
            let target = state.currentSpread
            let forward = target >= displayedSpread
            // Next comes from the right in left-to-right books, from the left in manga.
            let direction: UIPageViewController.NavigationDirection = (forward != state.rightToLeft) ? .forward : .reverse
            displayedSpread = target
            layoutVersion = state.layoutVersion
            rightToLeft = state.rightToLeft
            pageController = controller
            guard state.spreads.indices.contains(target) else { return }
            let page = makeController(target)
            controller.setViewControllers([page], direction: direction, animated: animated)
            followBackground(of: page)
        }

        private func makeController(_ spread: Int) -> SpreadViewController {
            let pieces = state.spreads[spread].map { SpreadViewController.Piece(page: $0, crop: state.cropRect(for: $0)) }
            let style = SpreadViewController.Style(
                fit: state.fit, background: state.background, bindingShadow: CGFloat(state.bindingShadow)
            )
            let controller = SpreadViewController(
                spreadIndex: spread, pieces: pieces, rightToLeft: state.rightToLeft,
                style: style, source: state.source, cache: state.cache, edgeColors: state.edgeColors
            )
            controller.onTap = { [weak self] fraction in self?.state.handleTap(atFraction: fraction) }
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

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? SpreadViewController else { return }
            displayedSpread = current.spreadIndex
            state.show(spread: current.spreadIndex)
            followBackground(of: current)
        }
    }
}

/// One screen: one or two pages side by side, zoomable.
final class SpreadViewController: UIViewController, UIScrollViewDelegate {
    /// One page on this screen: an image (or half of one) and the crop to show of it.
    struct Piece {
        let page: DisplayPage
        let crop: CGRect?
        var colorKey: NSString { "\(page)|\(crop.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-")" as NSString }
    }

    struct Style {
        let fit: ReaderState.Fit
        let background: ReaderOptions.Background
        /// 0 for none, up to 1.
        let bindingShadow: CGFloat
    }

    let spreadIndex: Int
    let pieces: [Piece]
    private let rightToLeft: Bool
    private let style: Style
    private let source: BookSource
    private let cache: PageImageCache
    private let edgeColors: NSCache<NSString, UIColor>
    var onTap: ((CGFloat) -> Void)?
    /// Called when a Match Page background has been worked out.
    var onBackgroundChange: (() -> Void)?
    private(set) var currentBackground: UIColor?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var imageViews: [UIImageView] = []
    private var spinners: [UIActivityIndicatorView] = []
    private var bindingShadow: BindingShadowView?
    private var loadTasks: [Task<Void, Never>] = []
    private var colorTask: Task<Void, Never>?
    private var loadedSize: CGFloat = 0
    private var laidOutContentSize: CGSize = .zero

    init(spreadIndex: Int, pieces: [Piece], rightToLeft: Bool, style: Style, source: BookSource,
         cache: PageImageCache, edgeColors: NSCache<NSString, UIColor>) {
        self.spreadIndex = spreadIndex
        self.pieces = pieces
        self.rightToLeft = rightToLeft
        self.style = style
        self.source = source
        self.cache = cache
        self.edgeColors = edgeColors
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTasks.forEach { $0.cancel() }
        colorTask?.cancel()
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
        }
        if pieces.count == 2, style.bindingShadow > 0 {
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
        view.accessibilityIdentifier = "reader-page"

        load(size: PageImageCache.screenPixelSize)
    }

    private var screenOrder: [Piece] { rightToLeft ? Array(pieces.reversed()) : pieces }

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
        let y = max(0, (area.height - height) / 2)
        for (view, aspect) in zip(imageViews, aspects) {
            view.frame = CGRect(x: x, y: y, width: height * aspect, height: height).integral
            view.subviews.first?.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            x += height * aspect
        }
        // Where the two pages meet, darkened a little like the fold of a printed book.
        if let bindingShadow, imageViews.count == 2 {
            let left = imageViews[0].frame, right = imageViews[1].frame
            let width = (min(left.width, right.width) * 0.16).rounded()
            let top = min(left.minY, right.minY), bottom = max(left.maxY, right.maxY)
            bindingShadow.frame = CGRect(x: left.maxX - width / 2, y: top, width: width, height: bottom - top)
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
        for (slot, piece) in screenOrder.enumerated() {
            let page = piece.page.page
            if let cached = cache.image(for: page, minSize: size) {
                display(cached, in: slot)
                continue
            }
            // Until the page is decoded, show a smaller copy if there is one, or a spinner, rather than a black page.
            if imageViews[slot].image == nil {
                if let smaller = cache.image(for: page, minSize: 0) {
                    display(smaller, in: slot)
                } else {
                    spinners[slot].startAnimating()
                }
            }
            let source = source, cache = cache
            loadTasks.append(Task { [weak self] in
                let image = await cache.load(page: page, size: size, from: source)
                guard let self, !Task.isCancelled else { return }
                self.spinners[slot].stopAnimating()
                guard let image else { return }
                self.display(image, in: slot)
                self.view.setNeedsLayout()
            })
        }
    }

    /// Puts a decoded image in its slot, cut to the half and crop this page shows.
    private func display(_ image: UIImage, in slot: Int) {
        let piece = screenOrder[slot]
        if let cgImage = image.cgImage, piece.page.isHalf || piece.crop != nil {
            imageViews[slot].image = UIImage(cgImage: PagePieces.cut(cgImage, part: piece.page.part, crop: piece.crop))
        } else {
            imageViews[slot].image = image
        }
        imageViews[slot].backgroundColor = .clear
        if style.background == .dynamic { matchBackground() }
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
        let peak = min(1, strength) * 0.55
        let alphas: [CGFloat] = [0, 0.08, 0.3, 1, 0.3, 0.08, 0]
        gradient.colors = alphas.map { UIColor.black.withAlphaComponent($0 * peak).cgColor }
        gradient.locations = [0, 0.22, 0.38, 0.5, 0.62, 0.78, 1]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
