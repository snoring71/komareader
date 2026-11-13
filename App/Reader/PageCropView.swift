import ArchiveKit
import ComicCore
import SwiftUI

/// Crops every page of a book by the same amount, to trim wide margins. Books whose margins
/// alternate can have one crop for odd pages and another for even pages.
struct PageCropView: View {
    let state: ReaderState
    @Environment(\.dismiss) private var dismiss

    @State private var alternate: Bool
    @State private var editingEven = false
    @State private var odd: CGRect
    @State private var even: CGRect
    @State private var image: UIImage?
    @State private var dragStart: CGRect?

    private static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let minimumSize: CGFloat = 0.2
    private static let canvasSpace = "page-crop-canvas"

    init(state: ReaderState) {
        self.state = state
        let crop = state.crop
        _alternate = State(initialValue: crop?.even != nil)
        _odd = State(initialValue: Self.rect(crop?.odd))
        _even = State(initialValue: Self.rect(crop?.even ?? crop?.odd))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Pages", selection: $alternate) {
                    Text("Same for All Pages").tag(false)
                    Text("Odd and Even Pages").tag(true)
                }
                .pickerStyle(.segmented)
                if alternate {
                    Picker("Editing", selection: $editingEven) {
                        Text("Odd Pages").tag(false)
                        Text("Even Pages").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                canvas
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Detect Margins", systemImage: "viewfinder") { detectMargins() }
                        .buttonStyle(.glass)
                        .disabled(image == nil)
                        .accessibilityIdentifier("crop-detect")
                    Button("No Crop", systemImage: "arrow.uturn.backward") { current = Self.whole }
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
        .task(id: previewPosition) {
            image = nil
            if let cgImage = await state.uncroppedImage(atPosition: previewPosition) {
                image = UIImage(cgImage: cgImage)
            }
        }
    }

    // MARK: Which crop and which page

    private var editingEvenPages: Bool { alternate && editingEven }

    private var current: CGRect {
        get { editingEvenPages ? even : odd }
        nonmutating set {
            if editingEvenPages { even = newValue } else { odd = newValue }
        }
    }

    /// The page shown: the one on screen in the reader, or its neighbour when that is the
    /// other kind (odd or even) from the crop being edited.
    private var previewPosition: Int {
        let position = state.currentPosition
        guard alternate else { return position }
        let wantsEven = editingEven
        // Position 0 is page 1, an odd page.
        if (position % 2 == 1) == wantsEven { return position }
        return position + 1 < state.displayPages.count ? position + 1 : max(0, position - 1)
    }

    private var caption: String {
        guard state.displayPages.indices.contains(previewPosition) else { return "" }
        let page = state.displayPages[previewPosition]
        let half: String
        switch page.part {
        case .whole: half = ""
        case .left: half = " (left half)"
        case .right: half = " (right half)"
        }
        let applies = alternate ? (editingEven ? "every even page" : "every odd page") : "every page"
        return "Showing page \(page.page + 1)\(half). This crop applies to \(applies) in the book. Drag the edges, or Detect Margins to trim plain borders."
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let display = displayRect(in: geo.size)
            let cropView = CGRect(x: display.minX + current.minX * display.width, y: display.minY + current.minY * display.height,
                                  width: current.width * display.width, height: current.height * display.height)
            ZStack(alignment: .topLeading) {
                if let image {
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
                        .offset(x: cropView.minX, y: cropView.minY)
                        .contentShape(Rectangle())
                        .gesture(moveGesture(display: display))
                    ForEach(Self.handles, id: \.self) { handle in
                        handleView(handle)
                            .position(x: cropView.minX + CGFloat(handle.x + 1) / 2 * cropView.width,
                                      y: cropView.minY + CGFloat(handle.y + 1) / 2 * cropView.height)
                            .gesture(resizeGesture(handle, display: display))
                    }
                } else {
                    ProgressView()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .coordinateSpace(name: Self.canvasSpace)
        }
        .accessibilityIdentifier("crop-canvas")
    }

    private func displayRect(in size: CGSize) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
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
        DragGesture(coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                let start = dragStart ?? current
                dragStart = start
                let dx = value.translation.width / max(display.width, 1)
                let dy = value.translation.height / max(display.height, 1)
                var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                let minimum = Self.minimumSize
                if handle.x < 0 { minX = min(max(0, start.minX + dx), maxX - minimum) }
                if handle.x > 0 { maxX = max(min(1, start.maxX + dx), minX + minimum) }
                if handle.y < 0 { minY = min(max(0, start.minY + dy), maxY - minimum) }
                if handle.y > 0 { maxY = max(min(1, start.maxY + dy), minY + minimum) }
                current = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func moveGesture(display: CGRect) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                let start = dragStart ?? current
                dragStart = start
                let dx = value.translation.width / max(display.width, 1)
                let dy = value.translation.height / max(display.height, 1)
                current.origin = CGPoint(x: min(max(0, start.minX + dx), 1 - start.width),
                                         y: min(max(0, start.minY + dy), 1 - start.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    // MARK: Actions

    private func detectMargins() {
        guard let cgImage = image?.cgImage else { return }
        let bounds = ImageAnalysis.contentBounds(of: cgImage)
        current = Self.rect(bounds)
    }

    private func save() {
        let oddValues = Self.values(odd)
        let evenValues = Self.values(even)
        let none = ReaderOptions.PageCrop.none
        let crop: ReaderOptions.PageCrop?
        if alternate {
            crop = oddValues == none && evenValues == none ? nil : .init(odd: oddValues, even: evenValues)
        } else {
            crop = oddValues == none ? nil : .init(odd: oddValues)
        }
        state.change { $0.crop = crop }
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
