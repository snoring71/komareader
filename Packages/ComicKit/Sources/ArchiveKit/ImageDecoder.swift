import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// All page decoding goes through ImageIO with downsampling, so we never hold a full-size
/// bitmap unless it is actually shown at full size.
public enum ImageDecoder {
    public static func downsample(url: URL, maxPixelSize: CGFloat) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ArchiveError(message: "Unreadable image \(url.lastPathComponent)")
        }
        return try downsample(source: source, maxPixelSize: maxPixelSize)
    }

    public static func downsample(data: Data, maxPixelSize: CGFloat) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ArchiveError(message: "Unreadable image")
        }
        return try downsample(source: source, maxPixelSize: maxPixelSize)
    }

    private static func downsample(source: CGImageSource, maxPixelSize: CGFloat) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ArchiveError(message: "Could not decode image")
        }
        return image
    }

    /// Pixel size after EXIF orientation, read from the header without decoding.
    public static func pixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    public static func jpegData(_ image: CGImage, quality: CGFloat = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
