import Foundation

/// Resolves local filesystem paths used by timeSlice.
public struct StoragePathResolver: @unchecked Sendable {
    public let rootDirectoryURL: URL

    private let calendar: Calendar

    public init(rootDirectoryURL: URL, calendar: Calendar = .current) {
        self.rootDirectoryURL = rootDirectoryURL
        self.calendar = calendar
    }

    public func dataDirectoryURL(for date: Date) -> URL {
        directoryURL(basePath: "data", date: date)
    }

    public func imageDirectoryURL(for date: Date) -> URL {
        directoryURL(basePath: "images", date: date)
    }

    public func reportDirectoryURL(for date: Date) -> URL {
        directoryURL(basePath: "reports", date: date)
    }

    public func buildRecordFileName(for record: CaptureRecord) -> String {
        let timestamp = makeTimestampString(from: record.capturedAt)
        let shortIdentifier = record.id.uuidString.prefix(4).lowercased()
        return "\(timestamp)_\(shortIdentifier).json"
    }

    public func buildImageFileName(capturedAt: Date, recordID: UUID) -> String {
        let timestamp = makeTimestampString(from: capturedAt)
        let shortIdentifier = recordID.uuidString.prefix(4).lowercased()
        return "\(timestamp)_\(shortIdentifier).png"
    }

    private func directoryURL(basePath: String, date: Date) -> URL {
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let year = dayComponents.year ?? 0
        let month = dayComponents.month ?? 0
        let day = dayComponents.day ?? 0

        return rootDirectoryURL
            .appendingPathComponent(basePath, isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }

    private func makeTimestampString(from date: Date) -> String {
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = timeComponents.hour ?? 0
        let minute = timeComponents.minute ?? 0
        let second = timeComponents.second ?? 0
        return String(format: "%02d%02d%02d", hour, minute, second)
    }
}
