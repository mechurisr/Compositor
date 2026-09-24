import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// PNG encoding for the assistant's read-only commands, kept apart from `ImageExporter`'s
/// (which serves saving and exporting) since neither owns the other and both are just the
/// same two-line `CGImageDestination` idiom already repeated at a few sites in this codebase.
enum PNGEncoding {
    nonisolated static func data(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw EditCommandError.renderFailed("could not create a PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EditCommandError.renderFailed("could not encode PNG data")
        }
        return data as Data
    }

    nonisolated static func base64(_ image: CGImage) throws -> String {
        try data(image).base64EncodedString()
    }

    /// Scales down to fit within `maxSide` on its longest edge; images already within it pass
    /// through unchanged, since upscaling would waste tokens without adding information.
    nonisolated static func fitted(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let scale = CGFloat(maxSide) / CGFloat(longest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EditCommandError.renderFailed("could not allocate a scaled surface")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else {
            throw EditCommandError.renderFailed("could not scale the render")
        }
        return scaled
    }
}
