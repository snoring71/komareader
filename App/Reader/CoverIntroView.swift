import SwiftUI
import UIKit

/// What the reader shows first when a book opens: its cover, on a gradient of the cover's own colour.
struct CoverIntro {
    /// The library thumbnail (the edited cover, if there is one), ready at once.
    let image: UIImage
    /// The cover's average colour, for the background.
    let color: UIColor
    /// The full-size cover, swapped in once it has been read.
    let fullSizeURL: URL?
    /// A book opened for the first time: the cover stays until the reader moves on to page 1.
    /// Otherwise it shows for a moment while the pages load, then gives way to them.
    let waits: Bool

    /// Settings › Book Defaults › Show Cover First.
    static let settingKey = "showCoverIntro"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }
}

struct CoverIntroView: View {
    let intro: CoverIntro
    /// Waits for the reader to move on (a first open, or the cover chosen from the page bar).
    let waits: Bool
    let rightToLeft: Bool
    /// The reader moved past the cover (swipe or tap towards the next page).
    let onForward: () -> Void
    let onToggleChrome: () -> Void
    /// Swiped up: close the book.
    let onClose: () -> Void
    /// For UI tests: the reader's cover, or the one in the pager before the first page.
    var identifier = "reader-cover-intro"

    @Environment(\.coverStyle) private var coverStyle
    @State private var fullSize: UIImage?
    /// Full-size covers already read, so a cover shown again (or the same cover shown in two
    /// places) starts sharp instead of switching from the thumbnail a moment later.
    private static let fullSizes = NSCache<NSURL, UIImage>()
    @State private var offset: CGSize = .zero
    @State private var leaving = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                cover(in: geo.size)
                    .offset(offset)
                    .scaleEffect(offset.height < 0 ? 1 + offset.height / 2000 : 1)
            }
            .contentShape(Rectangle())
            .gesture(drag(width: geo.size.width))
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                tap(atFraction: location.x / max(geo.size.width, 1), width: geo.size.width)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(waits && !leaving)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cover")
        .accessibilityHint(waits ? "Swipe to start reading" : "")
        .accessibilityAction(named: "Start Reading") { onForward() }
        .accessibilityIdentifier(identifier)
        .task { await loadFullSize() }
    }

    /// Lighter at the top, deeper at the bottom, like light falling on a table.
    private var background: some View {
        let color = intro.color
        return LinearGradient(
            colors: [Color(uiColor: color.mixed(with: .white, amount: 0.22)),
                     Color(uiColor: color.mixed(with: .black, amount: 0.15)),
                     Color(uiColor: color.mixed(with: .black, amount: 0.62))],
            startPoint: .top, endPoint: .bottom
        )
        .overlay {
            // A soft pool of light behind the cover.
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
        }
    }

    private func cover(in size: CGSize) -> some View {
        let image = fullSize ?? intro.fullSizeURL.flatMap { Self.fullSizes.object(forKey: $0 as NSURL) } ?? intro.image
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 2.0 / 3.0
        let height = min(size.height * 0.84, size.width * 0.84 / aspect)
        let radius = coverStyle.roundedCorners ? 8.0 : 0
        return Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: height * aspect, height: height)
            .overlay {
                // The spine: a fold of light and shade along the bound edge.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .white.opacity(0.18), location: 0.018),
                    .init(color: .black.opacity(0.12), location: 0.045),
                    .init(color: .clear, location: 0.09),
                ], startPoint: rightToLeft ? .trailing : .leading, endPoint: rightToLeft ? .leading : .trailing)
            }
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: rightToLeft ? radius : 2, bottomLeadingRadius: rightToLeft ? radius : 2,
                bottomTrailingRadius: rightToLeft ? 2 : radius, topTrailingRadius: rightToLeft ? 2 : radius,
                style: .continuous))
            // A tight contact shadow and a wide, soft one below, so the book sits on the surface.
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
            .shadow(color: .black.opacity(0.45), radius: 34, x: 0, y: 22)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let t = value.translation
                if abs(t.height) > abs(t.width) {
                    offset = CGSize(width: 0, height: min(0, t.height))
                } else {
                    let forward = rightToLeft ? t.width > 0 : t.width < 0
                    // Backwards there is nothing before the cover: it gives a little and returns.
                    offset = CGSize(width: forward ? t.width : t.width * 0.15, height: 0)
                }
            }
            .onEnded { value in
                let predicted = value.predictedEndTranslation
                if offset.height < -140 || (predicted.height < -320 && offset.height < -30) {
                    leaving = true
                    withAnimation(.easeIn(duration: 0.22)) { offset = CGSize(width: 0, height: -600) }
                    onClose()
                    return
                }
                let forward = rightToLeft ? predicted.width > width * 0.3 : predicted.width < -width * 0.3
                if forward {
                    leave(width: width)
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { offset = .zero }
                }
            }
    }

    /// Tap zones as on the pages: the side towards the next page moves on, the middle shows controls.
    private func tap(atFraction x: CGFloat, width: CGFloat) {
        let nextSide = rightToLeft ? x < 0.3 : x > 0.7
        let backSide = rightToLeft ? x > 0.7 : x < 0.3
        if nextSide {
            // A tap fades the cover away (the reader does it); a swipe slides it off.
            leaving = true
            onForward()
        } else if !backSide {
            onToggleChrome()
        }
    }

    /// Slides the cover off the way pages turn, then hands over to page 1.
    private func leave(width: CGFloat) {
        guard !leaving else { return }
        leaving = true
        withAnimation(.easeIn(duration: 0.25)) {
            offset = CGSize(width: rightToLeft ? width : -width, height: 0)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(230))
            onForward()
        }
    }

    private func loadFullSize() async {
        guard let url = intro.fullSizeURL, Self.fullSizes.object(forKey: url as NSURL) == nil else { return }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
        guard let image else { return }
        Self.fullSizes.setObject(image, forKey: url as NSURL)
        if !Task.isCancelled { fullSize = image }
    }
}

extension UIColor {
    /// This colour moved `amount` (0 to 1) of the way towards `other`.
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = min(max(amount, 0), 1)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
