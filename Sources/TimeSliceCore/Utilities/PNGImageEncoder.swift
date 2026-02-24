import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Supported image formats for capture image persistence.
public enum CaptureImageFormat: String, CaseIterable, Codable, Sendable {
    case png
    case jpg

    public var fileExtension: String {
        switch self {
        case .png:
            "png"
        case .jpg:
            "jpg"
        }
    }

    var utTypeIdentifier: CFString {
        switch self {
        case .png:
            UTType.png.identifier as CFString
        case .jpg:
            UTType.jpeg.identifier as CFString
        }
    }
}

/// Encodes `CGImage` into configured image data.
public enum CaptureImageEncoder {
    public static func encodeImage(_ image: CGImage, format: CaptureImageFormat) -> Data? {
        let mutableData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(
            mutableData,
            format.utTypeIdentifier,
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
