import LibraryKit
import SwiftUI
import UIKit

/// The page after a book's last page (#83): the next book where it was opened from (the next
/// one in a reading list or grid, or the series' next volume), with its cover on a Liquid
/// Glass card. Read Now closes this book and opens that one; Not Now turns back.
struct NextBookPage: View {
    let next: AppModel.NextBook
    let coverURL: URL?
    let coverRevision: Int
    let onRead: () -> Void
    let onBack: () -> Void

    @State private var backdrop: UIImage?

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let coverWidth = min(landscape ? geo.size.height * 0.36 : geo.size.width * 0.34, 300)
            ZStack {
                background
                VStack(spacing: 22) {
                    Text(next.heading)
                        .font(.subheadline.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("next-book-heading")
                    CoverImage(url: coverURL, title: next.book.title, revision: coverRevision)
                        .frame(width: coverWidth)
                    VStack(spacing: 4) {
                        Text(next.book.title)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        if let author = next.book.authors.first {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: coverWidth * 1.5)
                    HStack(spacing: 12) {
                        Button("Not Now", action: onBack)
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("next-book-back")
                        Button(action: onRead) {
                            // Inverse text on the black or white accent glass (#55).
                            Text(next.book.isDownloaded ? "Read Now" : "Download and Read")
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.onAccent)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("next-book-read")
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        // Light text and glass on the dark backdrop, in light mode too.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-next-book")
        .task(id: coverURL) { await loadBackdrop() }
    }

    /// The next cover, blurred and darkened, so the glass has something to bend.
    private var background: some View {
        ZStack {
            Color.black
            if let backdrop {
                Image(uiImage: backdrop)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 50)
                    .opacity(0.75)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
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
