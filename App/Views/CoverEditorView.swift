import ArchiveKit
import ComicCore
import LibraryKit
import SwiftUI

/// Edits a book's cover: pick any page, rotate it, crop it with handles (a loupe magnifies
/// under your finger while you drag an edge), with comic 2:3, original or free proportions.
/// Saving stores the recipe in the book's record and a rendered JPEG next to it.
struct CoverEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let book: Book
    /// The open book's pages, if the reader already has them.
    var source: BookSource?
    var initialEdit: BookRecord.CoverEdit?

    enum Aspect: String, CaseIterable, Identifiable {
        case comic = "Comic 2:3", original = "Original", free = "Free"
        var id: String { rawValue }
    }

    @State private var pages: BookSource?
    @State private var failedToOpen = false
    @State private var pageIndex = 0
    @State private var rotation = 0
    /// Crop as fractions of the rotated page, from the top left.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: Aspect = .free
    /// The chosen page, upright as stored in the book, decoded for editing.
    @State private var pageImage: CGImage?
    /// `pageImage` after rotation, as shown on the canvas.
    @State private var shown: UIImage?
    @State private var saving = false

    @State private var zoom: CGFloat = 1
    @State private var zoomAtStart: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero
    @State private var cropAtStart: CGRect?
    /// Where the finger is while dragging a crop handle, in canvas coordinates.
    @State private var loupePoint: CGPoint?

    private static let editPixelSize: CGFloat = 2400
    private static let minimumCrop: CGFloat = 0.05

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvas
                controls
                if let pages, pages.pageCount > 1 {
                    PageStrip(source: pages, selection: pageIndex) { choose(page: $0) }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Edit Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(pageImage == nil || saving)
                        .accessibilityIdentifier("cover-save")
                }
            }
        }
        .accessibilityIdentifier("cover-editor")
        .task { await start() }
    }

    // MARK: Canvas

    private static let canvasSpace = "cover-canvas"

    private var canvas: some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            if let shown {
                let display = displayRect(image: shown.size, in: canvasSize)
                let cropView = viewRect(of: crop, in: display)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .contentShape(Rectangle())
                        .gesture(panGesture)
                        .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = 1; pan = .zero } }
                    Image(uiImage: shown)
                        .resizable()
                        .frame(width: display.width, height: display.height)
                        .offset(x: display.minX, y: display.minY)
                        .allowsHitTesting(false)
                    // Dim everything outside the crop.
                    Path { path in
                        path.addRect(display)
                        path.addRect(cropView)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    cropFrame(cropView, display: display)
                    handles(cropView, display: display)
                    if let loupePoint {
                        loupe(at: loupePoint, display: display, cropView: cropView, canvas: canvasSize)
                    }
                }
                // Drags are measured on the canvas, not on the frame or handle being dragged: those move
                // with the finger, and measuring in their own space made the crop shake back and forth.
                .coordinateSpace(.named(Self.canvasSpace))
                .simultaneousGesture(zoomGesture)
            } else if failedToOpen {
                ContentUnavailableView("Could Not Open the Book", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }

    /// Where the page sits on the canvas: fitted with a margin, then zoomed and panned.
    private func displayRect(image: CGSize, in canvas: CGSize) -> CGRect {
        let area = CGSize(width: max(1, canvas.width - 48), height: max(1, canvas.height - 48))
        let scale = min(area.width / max(image.width, 1), area.height / max(image.height, 1)) * zoom
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2 + pan.width, y: (canvas.height - size.height) / 2 + pan.height,
                      width: size.width, height: size.height)
    }

    private func viewRect(of fraction: CGRect, in display: CGRect) -> CGRect {
        CGRect(x: display.minX + fraction.minX * display.width, y: display.minY + fraction.minY * display.height,
               width: fraction.width * display.width, height: fraction.height * display.height)
    }

    private func cropFrame(_ rect: CGRect, display: CGRect) -> some View {
        ZStack {
            Rectangle().stroke(Color.white, lineWidth: 2)
            // Rule of thirds, as in Photos.
            Path { path in
                for i in 1...2 {
                    let x = rect.width * CGFloat(i) / 3, y = rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .offset(x: rect.minX, y: rect.minY)
        .gesture(
            DragGesture(coordinateSpace: .named(Self.canvasSpace))
                .onChanged { value in
                    let start = cropAtStart ?? crop
                    cropAtStart = start
                    let dx = value.translation.width / display.width, dy = value.translation.height / display.height
                    crop.origin = CGPoint(x: min(max(0, start.minX + dx), 1 - start.width),
                                          y: min(max(0, start.minY + dy), 1 - start.height))
                }
                .onEnded { _ in cropAtStart = nil }
        )
        .accessibilityIdentifier("cover-crop")
    }

    // MARK: Handles

    /// A handle's place on the crop frame: -1, 0 or 1 across and down.
    private struct Handle: Hashable {
        let x: Int, y: Int
        var isCorner: Bool { x != 0 && y != 0 }
    }

    private var activeHandles: [Handle] {
        let corners = [Handle(x: -1, y: -1), Handle(x: 1, y: -1), Handle(x: 1, y: 1), Handle(x: -1, y: 1)]
        let edges = [Handle(x: 0, y: -1), Handle(x: 1, y: 0), Handle(x: 0, y: 1), Handle(x: -1, y: 0)]
        return aspect == .free ? corners + edges : corners
    }

    private func handles(_ rect: CGRect, display: CGRect) -> some View {
        ForEach(activeHandles, id: \.self) { handle in
            let point = CGPoint(x: rect.midX + CGFloat(handle.x) * rect.width / 2, y: rect.midY + CGFloat(handle.y) * rect.height / 2)
            HandleShape(isCorner: handle.isCorner, horizontal: handle.y != 0)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(coordinateSpace: .named(Self.canvasSpace))
                        .onChanged { value in
                            let start = cropAtStart ?? crop
                            cropAtStart = start
                            // Where the handle was when the drag began, plus how far the finger moved.
                            let startPoint = CGPoint(
                                x: display.minX + (handle.x < 0 ? start.minX : handle.x > 0 ? start.maxX : start.midX) * display.width,
                                y: display.minY + (handle.y < 0 ? start.minY : handle.y > 0 ? start.maxY : start.midY) * display.height
                            )
                            let target = CGPoint(x: startPoint.x + value.translation.width, y: startPoint.y + value.translation.height)
                            loupePoint = target
                            drag(handle, to: CGPoint(x: (target.x - display.minX) / display.width, y: (target.y - display.minY) / display.height), from: start)
                        }
                        .onEnded { _ in
                            cropAtStart = nil
                            loupePoint = nil
                        }
                )
                .position(point)
                .accessibilityIdentifier("cover-handle-\(handle.x)-\(handle.y)")
        }
    }

    /// Moves one handle to `point` (fractions of the page), keeping the proportions if locked.
    private func drag(_ handle: Handle, to point: CGPoint, from start: CGRect) {
        let minSize = Self.minimumCrop
        let fx = min(max(point.x, 0), 1), fy = min(max(point.y, 0), 1)
        if let ratio = lockedRatio, handle.isCorner {
            // The opposite corner stays put.
            let ax = handle.x < 0 ? start.maxX : start.minX
            let ay = handle.y < 0 ? start.maxY : start.minY
            let roomX = handle.x < 0 ? ax : 1 - ax
            let roomY = handle.y < 0 ? ay : 1 - ay
            var width = min(max(abs(fx - ax), minSize), roomX)
            var height = width * ratio
            if height > roomY { height = roomY; width = height / ratio }
            crop = CGRect(x: handle.x < 0 ? ax - width : ax, y: handle.y < 0 ? ay - height : ay, width: width, height: height)
            return
        }
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if handle.x < 0 { minX = min(fx, maxX - minSize) }
        if handle.x > 0 { maxX = max(fx, minX + minSize) }
        if handle.y < 0 { minY = min(fy, maxY - minSize) }
        if handle.y > 0 { maxY = max(fy, minY + minSize) }
        crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Crop height per crop width, both as fractions, for the locked proportions; nil when free.
    private var lockedRatio: CGFloat? {
        guard let shown, shown.size.height > 0 else { return nil }
        let pixelAspect: CGFloat
        switch aspect {
        case .free: return nil
        case .comic: pixelAspect = 2.0 / 3.0
        case .original: pixelAspect = shown.size.width / shown.size.height
        }
        return shown.size.width / (pixelAspect * shown.size.height)
    }

    // MARK: Loupe

    private func loupe(at point: CGPoint, display: CGRect, cropView: CGRect, canvas: CGSize) -> some View {
        let magnification: CGFloat = 3, size: CGFloat = 130
        let origin = CGPoint(x: size / 2 - point.x * magnification, y: size / 2 - point.y * magnification)
        return ZStack(alignment: .topLeading) {
            Color.black
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .frame(width: display.width * magnification, height: display.height * magnification)
                    .offset(x: origin.x + display.minX * magnification, y: origin.y + display.minY * magnification)
            }
            Path { path in
                path.addRect(CGRect(x: origin.x + cropView.minX * magnification, y: origin.y + cropView.minY * magnification,
                                    width: cropView.width * magnification, height: cropView.height * magnification))
            }
            .stroke(Color.yellow, lineWidth: 2)
            Path { path in
                path.move(to: CGPoint(x: size / 2 - 8, y: size / 2)); path.addLine(to: CGPoint(x: size / 2 + 8, y: size / 2))
                path.move(to: CGPoint(x: size / 2, y: size / 2 - 8)); path.addLine(to: CGPoint(x: size / 2, y: size / 2 + 8))
            }
            .stroke(Color.white, lineWidth: 1.5)
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 3))
        .shadow(radius: 8)
        // Above the finger, so the finger does not cover it; below it near the top edge.
        .position(x: min(max(size / 2, point.x), canvas.width - size / 2),
                  y: point.y - size * 0.95 > size / 2 ? point.y - size * 0.95 : point.y + size * 0.95)
        .allowsHitTesting(false)
    }

    // MARK: Zoom and pan

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoom = min(max(1, zoomAtStart * value.magnification), 5) }
            .onEnded { _ in
                zoomAtStart = zoom
                if zoom <= 1.01 { withAnimation(.snappy) { pan = .zero } }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard zoom > 1 else { return }
                pan = CGSize(width: panAtStart.width + value.translation.width, height: panAtStart.height + value.translation.height)
            }
            .onEnded { _ in panAtStart = pan }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                rotate()
            } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .accessibilityIdentifier("cover-rotate")

            Picker("Proportions", selection: Binding(get: { aspect }, set: { setAspect($0) })) {
                ForEach(Aspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Button {
                reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }
        .buttonStyle(.glass)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .disabled(shown == nil)
        .environment(\.colorScheme, .dark)
    }

    private func rotate() {
        rotation = (rotation + 90) % 360
        // Turn the crop with the page, so the same part of the page stays selected.
        crop = CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
        zoom = 1; zoomAtStart = 1; pan = .zero; panAtStart = .zero
        Task { await showRotated() }
    }

    private func setAspect(_ newValue: Aspect) {
        aspect = newValue
        applyAspect()
    }

    /// Makes the crop as large as the locked proportions allow, around its current centre.
    private func applyAspect() {
        guard let ratio = lockedRatio else { return }
        var width: CGFloat = 1
        var height = width * ratio
        if height > 1 { height = 1; width = height / ratio }
        let x = min(max(0, crop.midX - width / 2), 1 - width)
        let y = min(max(0, crop.midY - height / 2), 1 - height)
        crop = CGRect(x: x, y: y, width: width, height: height)
    }

    private func reset() {
        aspect = .free
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        zoom = 1; zoomAtStart = 1; pan = .zero; panAtStart = .zero
        if pageIndex != 0 {
            choose(page: 0)
        } else if rotation != 0 {
            rotation = 0
            Task { await showRotated() }
        }
    }

    private func choose(page: Int) {
        guard page != pageIndex || pageImage == nil else { return }
        pageIndex = page
        rotation = 0
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        Task { await loadPage(keepCrop: false) }
    }

    // MARK: Loading and saving

    private func start() async {
        guard pages == nil else { return }
        let opened: BookSource?
        if let source { opened = source } else { opened = await model.source(for: book) }
        guard let opened, opened.pageCount > 0 else { failedToOpen = true; return }
        pages = opened
        if let initialEdit, !initialEdit.isDefault, initialEdit.page < opened.pageCount, initialEdit.crop.count == 4 {
            pageIndex = initialEdit.page
            rotation = ((initialEdit.rotation % 360) + 360) % 360
            crop = CGRect(x: initialEdit.crop[0], y: initialEdit.crop[1], width: initialEdit.crop[2], height: initialEdit.crop[3])
        }
        await loadPage(keepCrop: true)
    }

    private func loadPage(keepCrop: Bool) async {
        guard let pages else { return }
        let index = pageIndex
        shown = nil
        guard let image = try? await pages.image(at: index, maxPixelSize: Self.editPixelSize), index == pageIndex else {
            if index == pageIndex { failedToOpen = true }
            return
        }
        pageImage = image
        await showRotated()
        if !keepCrop { applyAspect() }
    }

    private func showRotated() async {
        guard let pageImage else { return }
        let degrees = rotation
        let turned = await Task.detached(priority: .userInitiated) { CoverRenderer.rotate(pageImage, degrees: degrees) }.value
        guard degrees == rotation, let turned else { return }
        shown = UIImage(cgImage: turned)
    }

    private func save() async {
        guard let pageImage else { return }
        saving = true
        defer { saving = false }
        let edit = BookRecord.CoverEdit(
            page: pageIndex,
            crop: [Double(crop.minX), Double(crop.minY), Double(crop.width), Double(crop.height)].map { ($0 * 10000).rounded() / 10000 },
            rotation: rotation
        )
        let rendered = await Task.detached(priority: .userInitiated) {
            CoverRenderer.render(pageImage, crop: edit.crop, rotation: edit.rotation)
        }.value
        guard let rendered else { return }
        await model.saveCover(book, edit: edit, rendered: rendered)
        dismiss()
    }
}

/// A crop handle: an L for corners, a short bar for edges.
private struct HandleShape: View {
    let isCorner: Bool
    let horizontal: Bool

    var body: some View {
        ZStack {
            if isCorner {
                Circle().fill(Color.white).frame(width: 14, height: 14)
            } else {
                Capsule().fill(Color.white).frame(width: horizontal ? 28 : 6, height: horizontal ? 6 : 28)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
    }
}

/// A row of small page pictures to choose the cover page from.
private struct PageStrip: View {
    let source: BookSource
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(0..<source.pageCount, id: \.self) { page in
                        Button {
                            onSelect(page)
                        } label: {
                            PageThumbnail(source: source, page: page)
                                .frame(width: 52, height: 76)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(page == selection ? Color.accentColor : Color.clear, lineWidth: 3)
                                }
                        }
                        .buttonStyle(.plain)
                        .id(page)
                        .accessibilityLabel("Page \(page + 1)")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 96)
        .background(Color(white: 0.08))
    }
}

private struct PageThumbnail: View {
    let source: BookSource
    let page: Int
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.18)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Text("\(page + 1)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task {
                guard image == nil, let cgImage = try? await source.image(at: page, maxPixelSize: 160) else { return }
                image = UIImage(cgImage: cgImage)
            }
    }
}
