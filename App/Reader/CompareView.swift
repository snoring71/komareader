import ComicCore
import SwiftUI
import UIKit

/// Compare (from Image Adjustments): the pages on screen with their adjustments, and the
/// original while you press and hold, so you can see what the adjustments do. Done goes back.
struct CompareView: View {
    let state: ReaderState
    @State private var adjusted: [UIImage] = []
    @State private var original: [UIImage] = []
    @State private var showingOriginal = false

    var body: some View {
        ZStack {
            Color(uiColor: state.background.uiColor ?? .black).ignoresSafeArea()
            // Pinch or double-tap to zoom, drag to look around; hold still for the original,
            // and let go for the adjusted page again. Zoom stays put between the two.
            ComparePages(images: showingOriginal && !original.isEmpty ? original : adjusted) { holding in
                if showingOriginal != holding { showingOriginal = holding }
            }
            .ignoresSafeArea()
            .accessibilityIdentifier("compare-pages")
            if adjusted.isEmpty {
                ProgressView().controlSize(.large)
            }
            VStack {
                HStack {
                    Text(showingOriginal ? "Original" : "Adjusted")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("compare-label")
                    Spacer()
                    // The system glass button: an interactive glass effect on a plain button
                    // can take the touch itself and miss the tap.
                    Button("Done") { state.comparing = false }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .tint(.primary)
                        .accessibilityIdentifier("compare-done")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
                Text("Press and hold to see the original. Pinch to zoom.")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 20)
                    .opacity(showingOriginal ? 0 : 1)
            }
            .animation(.easeInOut(duration: 0.15), value: showingOriginal)
        }
        .statusBarHidden(true)
        .task { await load() }
    }

    /// Both versions of each page on screen, cut to the half and crop the reader shows.
    private func load() async {
        var shown = state.currentDisplayPages
        // Both halves of one image on screen: the whole image, as the reader draws it.
        if shown.count == 2, shown[0].page == shown[1].page, shown[0].isHalf, shown[1].isHalf {
            shown = [DisplayPage(page: shown[0].page)]
        }
        if state.rightToLeft { shown.reverse() }
        let adjustments = state.look.adjustments, size = PageImageCache.screenPixelSize
        let cache = state.cache, source = state.source
        var withLook: [UIImage] = [], plain: [UIImage] = []
        for page in shown {
            let crop = state.cropRect(for: page)
            func cut(_ image: UIImage?) -> UIImage? {
                guard let image, let cgImage = image.cgImage else { return image }
                guard page.isHalf || crop != nil else { return image }
                return UIImage(cgImage: PagePieces.cut(cgImage, part: page.part, crop: crop))
            }
            if let image = cut(await cache.load(page: page.page, size: size, from: source, adjustments: adjustments)) {
                withLook.append(image)
            }
            if let image = cut(await cache.load(page: page.page, size: size, from: source)) {
                plain.append(image)
            }
        }
        adjusted = withLook
        original = plain.count == withLook.count ? plain : []
    }
}

/// The pages side by side as the reader shows them (the first page on the right in manga),
/// in a scroll view that zooms. A press held without moving reports `onHold(true)` until
/// it lifts; pinching and dragging zoom and pan as usual.
struct ComparePages: UIViewRepresentable {
    let images: [UIImage]
    let onHold: (Bool) -> Void

    func makeUIView(context: Context) -> CompareScrollView {
        let view = CompareScrollView()
        view.onHold = onHold
        view.images = images
        return view
    }

    func updateUIView(_ view: CompareScrollView, context: Context) {
        view.onHold = onHold
        view.images = images
    }
}

final class CompareScrollView: UIScrollView, UIScrollViewDelegate {
    var onHold: ((Bool) -> Void)?
    /// Swapping in the other version keeps the zoom and position: the sizes match.
    var images: [UIImage] = [] {
        didSet {
            guard images.map(ObjectIdentifier.init) != oldValue.map(ObjectIdentifier.init) else { return }
            while imageViews.count < images.count {
                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                content.addSubview(imageView)
                imageViews.append(imageView)
            }
            for (index, imageView) in imageViews.enumerated() {
                imageView.image = index < images.count ? images[index] : nil
                imageView.isHidden = index >= images.count
            }
            let sizes = images.map(\.size)
            if sizes != laidOutSizes {
                laidOutSizes = sizes
                needsPageLayout = true
                setNeedsLayout()
            }
        }
    }
    private let content = UIView()
    private var imageViews: [UIImageView] = []
    private var laidOutSizes: [CGSize] = []
    private var laidOutBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        addSubview(content)

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.2
        hold.allowableMovement = 12
        addGestureRecognizer(hold)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutBounds || content.bounds.isEmpty || needsPageLayout else { return }
        needsPageLayout = false
        laidOutBounds = bounds.size
        layoutPages()
    }

    /// New page sizes to lay out (not set by zooming, which also lays out).
    private var needsPageLayout = false

    /// The pages fit to the screen at zoom 1, side by side, centred.
    private func layoutPages() {
        let area = bounds.inset(by: UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)).size
        guard area.width > 0, area.height > 0 else { return }
        let aspects = laidOutSizes.map { $0.height > 0 ? $0.width / $0.height : 2.0 / 3.0 }
        let total = max(aspects.reduce(0, +), 0.01)
        let height = min(area.height, area.width / total)
        zoomScale = 1
        content.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
        var x = (bounds.width - height * total) / 2
        let y = (bounds.height - height) / 2
        for (imageView, aspect) in zip(imageViews, aspects) {
            imageView.frame = CGRect(x: x.rounded(), y: y.rounded(), width: (height * aspect).rounded(), height: height.rounded())
            x += height * aspect
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: onHold?(true)
        case .ended, .cancelled, .failed: onHold?(false)
        default: break
        }
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: content)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
