import Foundation

public enum CaptureTrigger: String, Codable, Sendable {
    case scheduled
    case manual
}

/// One OCR capture entry stored by timeSlice.
public struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let applicationName: String
    public let windowTitle: String?
    public let capturedAt: Date
    public let ocrText: String
    public let hasImage: Bool
    public let captureTrigger: CaptureTrigger
    public let comments: String?

    public init(
        id: UUID = UUID(),
        applicationName: String,
        windowTitle: String? = nil,
        capturedAt: Date,
        ocrText: String,
        hasImage: Bool,
        captureTrigger: CaptureTrigger = .scheduled,
        comments: String? = nil
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
        self.ocrText = ocrText
        self.hasImage = hasImage
        self.captureTrigger = captureTrigger
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case applicationName
        case windowTitle
        case capturedAt
        case ocrText
        case hasImage
        case captureTrigger
        case comments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        ocrText = try container.decode(String.self, forKey: .ocrText)
        hasImage = try container.decode(Bool.self, forKey: .hasImage)
        captureTrigger = try container.decodeIfPresent(CaptureTrigger.self, forKey: .captureTrigger) ?? .scheduled
        comments = try container.decodeIfPresent(String.self, forKey: .comments)
    }
}
