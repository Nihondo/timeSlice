import CoreGraphics
import Foundation

/// One captured foreground window image and metadata.
public struct CapturedWindow: @unchecked Sendable {
    public let image: CGImage
    public let applicationName: String
    public let capturedAt: Date

    public init(image: CGImage, applicationName: String, capturedAt: Date) {
        self.image = image
        self.applicationName = applicationName
        self.capturedAt = capturedAt
    }
}

/// Captures the frontmost window image.
public protocol ScreenCapturing: Sendable {
    func captureFrontWindow() async throws -> CapturedWindow?
}

public enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case frontmostApplicationNotFound
    case targetWindowNotFound(applicationName: String)
    case selfApplicationSkipped

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission is not granted."
        case .frontmostApplicationNotFound:
            return "Frontmost application was not found."
        case let .targetWindowNotFound(applicationName):
            return "Target window was not found for \(applicationName)."
        case .selfApplicationSkipped:
            return "Capture skipped for this application."
        }
    }
}
