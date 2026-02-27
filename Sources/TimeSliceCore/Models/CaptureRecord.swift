import Foundation

public enum CaptureTrigger: String, Codable, Sendable {
    case scheduled
    case manual
    case rectangleCapture
}

/// One OCR capture entry stored by timeSlice.
public struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let applicationName: String
    public let windowTitle: String?
    public let capturedAt: Date
    public let ocrText: String
    public let hasImage: Bool
    public let imageFormat: CaptureImageFormat?
    public let captureTrigger: CaptureTrigger
    public let comments: String?
    public let browserURL: String?
    public let documentPath: String?

    public init(
        id: UUID = UUID(),
        applicationName: String,
        windowTitle: String? = nil,
        capturedAt: Date,
        ocrText: String,
        hasImage: Bool,
        imageFormat: CaptureImageFormat? = nil,
        captureTrigger: CaptureTrigger = .scheduled,
        comments: String? = nil,
        browserURL: String? = nil,
        documentPath: String? = nil
    ) {
        self.id = id
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
        self.ocrText = ocrText
        self.hasImage = hasImage
        self.imageFormat = imageFormat
        self.captureTrigger = captureTrigger
        self.comments = comments
        self.browserURL = browserURL
        self.documentPath = documentPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case applicationName
        case windowTitle
        case capturedAt
        case ocrText
        case hasImage
        case imageFormat
        case captureTrigger
        case comments
        case browserURL
        case documentPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        applicationName = try container.decode(String.self, forKey: .applicationName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        ocrText = try container.decode(String.self, forKey: .ocrText)
        hasImage = try container.decode(Bool.self, forKey: .hasImage)
        imageFormat = try container.decodeIfPresent(CaptureImageFormat.self, forKey: .imageFormat)
        captureTrigger = try container.decodeIfPresent(CaptureTrigger.self, forKey: .captureTrigger) ?? .scheduled
        comments = try container.decodeIfPresent(String.self, forKey: .comments)
        browserURL = try container.decodeIfPresent(String.self, forKey: .browserURL)
        documentPath = try container.decodeIfPresent(String.self, forKey: .documentPath)
    }
}

/// Represents image linkage status for one capture record.
public enum CaptureImageLinkState: String, Equatable, Sendable {
    case available
    case notCaptured
    case missingOrExpired
}

/// One viewer-friendly capture item that links JSON and image files.
public struct CaptureRecordArtifact: Identifiable, Equatable, Sendable {
    public let record: CaptureRecord
    public let jsonFileURL: URL
    public let imageFileURL: URL?
    public let imageLinkState: CaptureImageLinkState

    public var id: UUID {
        record.id
    }

    public init(
        record: CaptureRecord,
        jsonFileURL: URL,
        imageFileURL: URL?,
        imageLinkState: CaptureImageLinkState
    ) {
        self.record = record
        self.jsonFileURL = jsonFileURL
        self.imageFileURL = imageFileURL
        self.imageLinkState = imageLinkState
    }
}
