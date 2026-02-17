import Foundation

/// One OCR capture entry stored by timeSlice.
public struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let applicationName: String
    public let windowTitle: String?
    public let capturedAt: Date
    public let ocrText: String
    public let hasImage: Bool

    public init(
        id: UUID = UUID(),
        applicationName: String,
        windowTitle: String? = nil,
        capturedAt: Date,
        ocrText: String,
        hasImage: Bool
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
        self.ocrText = ocrText
        self.hasImage = hasImage
    }
}
