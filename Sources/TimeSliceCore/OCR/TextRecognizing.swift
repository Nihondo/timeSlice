import CoreGraphics
import Foundation

/// Recognizes text from a captured image.
public protocol TextRecognizing: Sendable {
    func recognizeText(from image: CGImage) async throws -> String
}
