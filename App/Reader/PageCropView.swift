import ArchiveKit
import ComicCore
import SwiftUI

/// Trims the margins of every page in a book. Shows a left page and a right page side by
/// side (or the two halves of an image that holds both), each with its own crop; Mirror keeps
/// the two crops flipped copies of each other, so outer and inner margins match.
struct PageCropView: View {
    typealias Link = ReaderOptions.PageCrop.Link

    let state: ReaderState
    @Environment(\.dismiss) private var dismiss

    @State private var link: Link
    @State private var left: CGRect
    @State private var right: CGRect
    @State private var leftImage: UIImage?
    @State private var rightImage: UIImage?
    @State private var sameImage = false
    @State private var loaded = false

    private static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(state: ReaderState) {
        self.state = state
        let crop = state.crop
        _link = State(initialValue: crop?.link ?? .mirrored)
        _left = State(initialValue: Self.rect(crop?.left))
        _right = State(initialValue: Self.rect(crop?.right))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ChoiceBar<Link>([(.mirrored, "Mirror"), (.same, "Same on Both"), (.separate, "Separate")], selection: $link)
                    .frame(maxWidth: 520)
                .accessibilityIdentifier("crop-link")

                if loaded {
                    HStack(alignment: .top, spacing: sameImage ? 0 : 24) {
                        CropCanvas(title: "Left Page", image: leftImage, rect: leftBinding, alignment: .trailing, space: "crop-left")
                        CropCanvas(title: "Right Page", image: rightImage, rect: rightBinding, alignment: .leading, space: "crop-right")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Detect Margins", systemImage: "viewfinder") { detectMargins() }
                        .buttonStyle(.glass)
                        .disabled(leftImage == nil && rightImage == nil)
                        .accessibilityIdentifier("crop-detect")
                    Button("No Crop", systemImage: "arrow.uturn.backward") {
                        left = Self.whole
                        right = Self.whole
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Crop Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier("crop-save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: link) { _, _ in follow(left, from: .left) }
        .task {
            let preview = await state.cropPreview()
            leftImage = preview.left.map { UIImage(cgImage: $0) }
            rightImage = preview.right.map { UIImage(cgImage: $0) }
            sameImage = preview.sameImage
            loaded = true
        }
    }

    private var caption: String {
        let what = sameImage
            ? "This image holds two pages, so each half has its own crop. Split Double Pages splits it after cropping."
            : "Left pages and right pages each have their own crop, as they sit in a two-page spread."
        let how: String
        switch link {
        case .mirrored: how = "Mirror flips one side's crop onto the other, so the outer margins match."
        case .same: how = "Both sides use the same crop."
        case .separate: how = "Each side is cropped on its own."
        }
        return "\(what) \(how) The crop applies to every page in the book."
    }

    // MARK: Keeping the sides linked

    private enum Side { case left, right }

    private var leftBinding: Binding<CGRect> {
        Binding(get: { left }, set: { follow($0, from: .left) })
    }

    private var rightBinding: Binding<CGRect> {
        Binding(get: { right }, set: { follow($0, from: .right) })
    }

    /// Sets one side's crop and, unless the sides are separate, the other side's to match.
    private func follow(_ rect: CGRect, from side: Side) {
        let other: CGRect
        switch link {
        case .mirrored: other = Self.mirror(rect)
        case .same: other = rect
        case .separate: other = side == .left ? right : left
        }
        if side == .left {
            left = rect
            right = other
        } else {
            right = rect
            left = other
        }
    }

    private static func mirror(_ rect: CGRect) -> CGRect {
        CGRect(x: max(0, 1 - rect.maxX), y: rect.minY, width: rect.width, height: rect.height)
    }

    // MARK: Actions

    /// Finds the plain margins on each page shown. Linked sides keep whatever either page
    /// needs, so no art is trimmed from the other.
    private func detectMargins() {
        let foundLeft = leftImage?.cgImage.map { Self.rect(ImageAnalysis.contentBounds(of: $0)) }
        let foundRight = rightImage?.cgImage.map { Self.rect(ImageAnalysis.contentBounds(of: $0)) }
        switch link {
        case .separate:
            if let foundLeft { left = foundLeft }
            if let foundRight { right = foundRight }
        case .mirrored:
            let candidates = [foundLeft, foundRight.map(Self.mirror)].compactMap { $0 }
            guard let first = candidates.first else { return }
            follow(candidates.dropFirst().reduce(first) { $0.union($1) }, from: .left)
        case .same:
            let candidates = [foundLeft, foundRight].compactMap { $0 }
            guard let first = candidates.first else { return }
            follow(candidates.dropFirst().reduce(first) { $0.union($1) }, from: .left)
        }
    }

    private func save() {
        let crop = ReaderOptions.PageCrop(left: Self.values(left), right: Self.values(right), link: link)
        state.change { $0.crop = crop.isNone ? nil : crop }
        dismiss()
    }

    private static func rect(_ values: [Double]?) -> CGRect {
        guard let values, values.count == 4 else { return whole }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// The crop as stored: fractions rounded to 4 places, so an untouched edge reads as exactly 0 or 1.
    private static func values(_ rect: CGRect) -> [Double] {
        func round(_ value: CGFloat) -> Double { (Double(value) * 10_000).rounded() / 10_000 }
        let x = max(0, round(rect.minX)), y = max(0, round(rect.minY))
        return [x, y, min(1 - x, round(rect.width)), min(1 - y, round(rect.height))]
    }
}

/// One page with a crop frame: drag an edge or corner to resize it, or the middle to move it.
private struct CropCanvas: View {
    let title: String
    let image: UIImage?
    @Binding var rect: CGRect
    /// Which way the page hugs its half of the screen, so two halves of one image meet.
    let alignment: HorizontalAlignment
    let space: String

    @State private var dragStart: CGRect?
    private static let minimumSize: CGFloat = 0.2

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                if let image {
                    let display = displayRect(for: image, in: geo.size)
                    let cropView = CGRect(x: display.minX + rect.minX * display.width, y: display.minY + rect.minY * display.height,
                                          width: rect.width * display.width, height: rect.height * display.height)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: display.width, height: display.height)
                            .offset(x: display.minX, y: display.minY)
                        Path { path in
                            path.addRect(display)
                            path.addRect(cropView)
                        }
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 2)
                            .frame(width: cropView.width, height: cropView.height)
                            .contentShape(Rectangle())
                            .offset(x: cropView.minX, y: cropView.minY)
                            .gesture(moveGesture(display: display))
                        ForEach(Self.handles, id: \.self) { handle in
                            handleView(handle)
                                .position(x: cropView.minX + CGFloat(handle.x + 1) / 2 * cropView.width,
                                          y: cropView.minY + CGFloat(handle.y + 1) / 2 * cropView.height)
                                .gesture(resizeGesture(handle, display: display))
                        }
                    }
                    .coordinateSpace(name: space)
                } else {
                    Text("No page on this side here")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .accessibilityIdentifier("crop-canvas")
    }

    private func displayRect(for image: UIImage, in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        let x: CGFloat
        switch alignment {
        case .leading: x = 0
        case .trailing: x = size.width - width
        default: x = (size.width - width) / 2
        }
        return CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
    }

    /// A handle's place on the crop frame: -1, 0 or 1 across and down.
    private struct Handle: Hashable {
        let x: Int
        let y: Int
    }

    private static let handles: [Handle] = [
        Handle(x: -1, y: -1), Handle(x: 0, y: -1), Handle(x: 1, y: -1),
        Handle(x: -1, y: 0), Handle(x: 1, y: 0),
        Handle(x: -1, y: 1), Handle(x: 0, y: 1), Handle(x: 1, y: 1),
    ]

    private func handleView(_ handle: Handle) -> some View {
        let corner = handle.x != 0 && handle.y != 0
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: corner ? 18 : (handle.x == 0 ? 34 : 8), height: corner ? 18 : (handle.y == 0 ? 34 : 8))
            .shadow(radius: 2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func resizeGesture(_ handle: Handle, display: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(space))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let dx = value.translation.width / max(display.width, 1)
                let dy = value.translation.height / max(display.height, 1)
                var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                let minimum = Self.minimumSize
                if handle.x < 0 { minX = min(max(0, start.minX + dx), maxX - minimum) }
                if handle.x > 0 { maxX = max(min(1, start.maxX + dx), minX + minimum) }
                if handle.y < 0 { minY = min(max(0, start.minY + dy), maxY - minimum) }
                if handle.y > 0 { maxY = max(min(1, start.maxY + dy), minY + minimum) }
                rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moveGesture(display: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(space))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let dx = value.translation.width / max(display.width, 1)
                let dy = value.translation.height / max(display.height, 1)
                rect = CGRect(x: min(max(0, start.minX + dx), 1 - start.width),
                              y: min(max(0, start.minY + dy), 1 - start.height),
                              width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }
}
