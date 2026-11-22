import LibraryKit
import SwiftUI
import UIKit

/// The page after a book's last page (#83): the next book where it was opened from (the next
/// one in a reading list or grid, or the series' next volume), with its cover on a Liquid
/// Glass card. Read Now opens it right here in the reader, downloading it first if it is only
/// in iCloud; Not Now turns back.
struct NextBookPage: View {
    @Environment(AppModel.self) private var model
    let next: AppModel.NextBook
    /// The book just finished, to rate here (#129).
    var finishedId: String?
    let coverURL: URL?
    let coverRevision: Int
    let onBack: () -> Void

    @State private var backdrop: UIImage?
    /// Read Now was tapped on a book still in iCloud: it downloads, then opens.
    @State private var waiting = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let coverWidth = landscape ? min(geo.size.height * 0.34, 260) : min(geo.size.width * 0.34, 300)
            ZStack {
                background(size: geo.size)
                card(coverWidth: coverWidth, landscape: landscape)
                    .padding(32)
                if let finishedId, let finished = model.book(id: finishedId) {
                    VStack {
                        ratingBar(for: finished)
                            .padding(.top, landscape ? 20 : 48)
                        Spacer()
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        // Light text and glass on the dark backdrop, in light mode too.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-next-book")
        .task(id: coverURL) { await loadBackdrop() }
    }

    @ViewBuilder private func card(coverWidth: CGFloat, landscape: Bool) -> some View {
        let cover = CoverImage(url: coverURL, title: next.book.title, revision: coverRevision)
            .frame(width: coverWidth)
        Group {
            if landscape {
                // Side by side, so the card fits the short screen.
                HStack(spacing: 32) {
                    cover
                    details(width: max(coverWidth * 1.3, 340), alignment: .leading)
                }
            } else {
                VStack(spacing: 22) {
                    heading
                    cover
                    details(width: coverWidth * 1.5, alignment: .center, showsHeading: false)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
    }

    /// Rate the book just finished, in passing (#129). Tapping the same star again removes it.
    private func ratingBar(for book: Book) -> some View {
        HStack(spacing: 14) {
            Text("Rate \(book.title)")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 320, alignment: .leading)
            StarRating(value: book.rating, size: 20) { value in
                model.setRating([book.id], value)
            }
            .accessibilityIdentifier("next-book-rating")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }

    private var heading: some View {
        Text(next.heading)
            .font(.subheadline.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("next-book-heading")
    }

    private func details(width: CGFloat, alignment: HorizontalAlignment, showsHeading: Bool = true) -> some View {
        let textAlignment: TextAlignment = alignment == .leading ? .leading : .center
        return VStack(alignment: alignment, spacing: 20) {
            if showsHeading { heading }
            VStack(alignment: alignment, spacing: 4) {
                Text(next.book.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(textAlignment)
                    .lineLimit(3)
                if let author = next.book.authors.first {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            actions
        }
        .frame(maxWidth: width, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private var actions: some View {
        let id = next.book.id
        let book = model.book(id: id) ?? next.book
        let downloading = model.downloading.contains(id) || model.queuedDownloads.contains(id)
        return VStack(alignment: .leading, spacing: 14) {
            if downloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if model.downloadProgress[id] == nil { ProgressView().controlSize(.small) }
                        Text("Downloading…").font(.subheadline.weight(.medium))
                    }
                    if let progress = model.downloadProgress[id] {
                        ProgressView(value: progress)
                            .tint(.white)
                            .frame(width: 200)
                    }
                }
                .accessibilityIdentifier("next-book-downloading")
            }
            HStack(spacing: 12) {
                Button("Not Now") {
                    // A download goes on, but the book no longer opens by itself.
                    model.cancelNextInReader()
                    waiting = false
                    onBack()
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("next-book-back")
                // Once asked for, it opens by itself when it is in.
                if !waiting {
                    Button {
                        if !book.isDownloaded { waiting = true }
                        Task {
                            await model.readNextInReader(book)
                            waiting = false
                        }
                    } label: {
                        // Inverse text on the black or white accent glass (#55).
                        Text(book.isDownloaded ? "Read Now" : downloading ? "Read When Ready" : "Download & Read")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.onAccent)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("next-book-read")
                }
            }
            .controlSize(.large)
        }
    }

    /// The next cover, blurred and darkened, so the glass has something to bend. Sized to the
    /// screen: a filled image reports its own (larger) size, which pushed the card off screen
    /// in landscape.
    private func background(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 50)
                    .opacity(0.75)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func loadBackdrop() async {
        guard let url = coverURL else { return }
        let revision = coverRevision
        if let cached = CoverMemoryCache.shared.image(for: url, revision: revision) {
            backdrop = cached
            return
        }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }.value
        withAnimation(.easeOut(duration: 0.3)) { backdrop = image }
    }
}
