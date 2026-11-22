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
            pages(showingOriginal && !original.isEmpty ? original : adjusted)
                .padding(.vertical, 8)
                .ignoresSafeArea(edges: .horizontal)
                .contentShape(Rectangle())
                // Hold anywhere for the original; let go for the adjusted page again.
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !showingOriginal { showingOriginal = true } }
                    .onEnded { _ in showingOriginal = false })
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
                Text("Press and hold to see the original")
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

    /// The pages side by side as the reader shows them (the first page on the right in manga).
    private func pages(_ images: [UIImage]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
