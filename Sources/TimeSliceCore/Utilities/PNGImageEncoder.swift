import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes `CGImage` into PNG data.
public enum PNGImageEncoder {
    public static func encodeImage(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else {
            return nil
        }

        return mutableData as Data
    }
}
