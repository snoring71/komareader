import CoreImage
import Metal
import MetalFX

/// Doubles the resolution of small scans on the GPU (#121), with Apple's MetalFX spatial
/// scaler: an edge-aware upscaler built into the system, so there is no model to license or
/// ship. A trial: it is tuned for rendered games, so how it suits scanned line art is what
/// testing on real books should show.
enum PageUpscaler {
    /// Pages whose long side is smaller than this are upscaled (iPad screens are about 2,400
    /// to 2,750 pixels on their long side).
    static let smallPage = 1800

    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let lock = NSLock()

    /// Whether this device can upscale at all.
    static var isSupported: Bool {
        guard let device else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    /// `image` at twice its size, or nil when it is big enough already or the GPU can't.
    static func upscale(_ image: CIImage, context: CIContext) -> CIImage? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard max(width, height) < smallPage, width >= 16, height >= 16,
              let device, let queue, MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }
        return lock.withLock { () -> CIImage? in
            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            inputDescriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            inputDescriptor.storageMode = .private
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width * 2, height: height * 2, mipmapped: false)
            outputDescriptor.usage = [.shaderRead, .renderTarget]
            outputDescriptor.storageMode = .private
            guard let input = device.makeTexture(descriptor: inputDescriptor),
                  let output = device.makeTexture(descriptor: outputDescriptor),
                  let buffer = queue.makeCommandBuffer() else { return nil }

            // The page into the input texture (Core Image draws with its origin at the bottom).
            let placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            context.render(placed, to: input, commandBuffer: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())

            let descriptor = MTLFXSpatialScalerDescriptor()
            descriptor.inputWidth = width
            descriptor.inputHeight = height
            descriptor.outputWidth = width * 2
            descriptor.outputHeight = height * 2
            descriptor.colorTextureFormat = .rgba8Unorm
            descriptor.outputTextureFormat = .rgba8Unorm
            descriptor.colorProcessingMode = .perceptual
            guard let scaler = descriptor.makeSpatialScaler(device: device) else { return nil }
            scaler.colorTexture = input
            scaler.outputTexture = output
            scaler.inputContentWidth = width
            scaler.inputContentHeight = height
            scaler.encode(commandBuffer: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed,
                  let result = CIImage(mtlTexture: output, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any]) else { return nil }
            // Back to where the page was, at twice the size.
            return result.transformed(by: CGAffineTransform(translationX: extent.minX * 2, y: extent.minY * 2))
        }
    }
}
