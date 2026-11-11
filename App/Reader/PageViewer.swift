import ArchiveKit
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
            controller.setViewControllers([makeController(target)], direction: direction, animated: animated)
        }

        private func makeController(_ spread: Int) -> SpreadViewController {
            let controller = SpreadViewController(
                spreadIndex: spread, pages: state.spreads[spread], rightToLeft: state.rightToLeft,
                source: state.source, cache: state.cache
            )
            controller.onTap = { [weak self] fraction in self?.state.handleTap(atFraction: fraction) }
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

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pvc.viewControllers?.first as? SpreadViewController else { return }
            displayedSpread = current.spreadIndex
            state.show(spread: current.spreadIndex)
        }
    }
}

/// One screen: one or two pages side by side, zoomable.
final class SpreadViewController: UIViewController, UIScrollViewDelegate {
    let spreadIndex: Int
    let pages: [Int]
    private let rightToLeft: Bool
    private let source: BookSource
    private let cache: PageImageCache
    var onTap: ((CGFloat) -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private var imageViews: [UIImageView] = []
    private var loadTasks: [Task<Void, Never>] = []
    private var loadedSize: CGFloat = 0

    init(spreadIndex: Int, pages: [Int], rightToLeft: Bool, source: BookSource, cache: PageImageCache) {
        self.spreadIndex = spreadIndex
        self.pages = pages
        self.rightToLeft = rightToLeft
        self.source = source
        self.cache = cache
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { loadTasks.forEach { $0.cancel() } }

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

    private var screenOrder: [Int] { rightToLeft ? Array(pages.reversed()) : pages }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.zoomScale == 1 {
            contentView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
            scrollView.contentSize = scrollView.bounds.size
        }
        layoutPages()
    }

    /// Fits the page(s) into the screen, side by side, keeping each page's aspect ratio.
    private func layoutPages() {
        let bounds = CGRect(origin: .zero, size: scrollView.bounds.size).insetBy(dx: 0, dy: 0)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let aspects = imageViews.map { view -> CGFloat in
            guard let size = view.image?.size, size.height > 0 else { return 2.0 / 3.0 }
            return size.width / size.height
        }
        let totalAspect = aspects.reduce(0, +)
        let height = min(bounds.height, bounds.width / totalAspect)
        var x = (bounds.width - height * totalAspect) / 2
        let y = (bounds.height - height) / 2
        for (view, aspect) in zip(imageViews, aspects) {
            view.frame = CGRect(x: x, y: y, width: height * aspect, height: height).integral
            x += height * aspect
        }
    }

    private func load(size: CGFloat) {
        guard size > loadedSize else { return }
        loadedSize = size
        for (slot, page) in screenOrder.enumerated() {
            if let cached = cache.image(for: page, minSize: size) {
                imageViews[slot].image = cached
                continue
            }
            let source = source, cache = cache
            loadTasks.append(Task { [weak self] in
                guard let cgImage = try? await source.image(at: page, maxPixelSize: size), !Task.isCancelled else { return }
                let image = UIImage(cgImage: cgImage)
                cache.insert(image, for: page, size: size)
                guard let self else { return }
                self.imageViews[slot].image = image
                self.view.setNeedsLayout()
            })
        }
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
