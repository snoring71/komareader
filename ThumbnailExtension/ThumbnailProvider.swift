import ArchiveKit
import ComicCore
import QuickLookThumbnailing
import UIKit

/// Shows the first page of CBZ, CBR, CB7 and CBT files as their icon in the Files app.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        guard let format = BookFormat.from(pathExtension: url.pathExtension), format.isArchive else {
            handler(nil, nil)
            return
        }
        let maximum = request.maximumSize
        let pixels = max(maximum.width, maximum.height) * request.scale
        Task {
            do {
                let page = try await BookSourceFactory.firstPageImage(url: url, format: format, maxPixelSize: max(pixels, 64))
                let image = UIImage(cgImage: page)
                // Fit inside the size Files asked for, keeping the page's shape.
                let scale = min(maximum.width / max(image.size.width, 1), maximum.height / max(image.size.height, 1))
                let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
                let reply = QLThumbnailReply(contextSize: size) { () -> Bool in
                    image.draw(in: CGRect(origin: .zero, size: size))
                    return true
                }
                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }
}
