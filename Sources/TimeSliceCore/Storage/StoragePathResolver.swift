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

    public func buildImageFileName(
        capturedAt: Date,
        recordID: UUID,
        imageFormat: CaptureImageFormat
    ) -> String {
        let timestamp = makeTimestampString(from: capturedAt)
        let shortIdentifier = recordID.uuidString.prefix(4).lowercased()
        return "\(timestamp)_\(shortIdentifier).\(imageFormat.fileExtension)"
    }

    public func buildImageFileNameCandidates(capturedAt: Date, recordID: UUID) -> [String] {
        CaptureImageFormat.allCases.map { imageFormat in
            buildImageFileName(
                capturedAt: capturedAt,
                recordID: recordID,
                imageFormat: imageFormat
            )
        }
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

enum StorageMaintenance {
    static func ensureDirectoryExists(at directoryURL: URL, fileManager: FileManager) throws {
        let hasDirectory = fileManager.fileExists(atPath: directoryURL.path)
        guard hasDirectory == false else {
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    static func cleanupExpiredDayDirectories(
        in baseDirectoryURL: URL,
        retentionDays: Int,
        referenceDate: Date,
        fileManager: FileManager,
        calendar: Calendar
    ) throws -> [URL] {
        let hasBaseDirectory = fileManager.fileExists(atPath: baseDirectoryURL.path)
        guard hasBaseDirectory else {
            return []
        }

        guard let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: referenceDate) else {
            return []
        }

        let dayCutoffDate = calendar.startOfDay(for: cutoffDate)
        let dayDirectoryURLs = try collectDayDirectoryURLs(
            in: baseDirectoryURL,
            fileManager: fileManager,
            calendar: calendar
        )
        var removedDirectoryURLs: [URL] = []

        for dayDirectoryURL in dayDirectoryURLs {
            guard let dayDate = parseDayDate(from: dayDirectoryURL, calendar: calendar) else {
                continue
            }
            guard dayDate < dayCutoffDate else {
                continue
            }

            try fileManager.removeItem(at: dayDirectoryURL)
            removedDirectoryURLs.append(dayDirectoryURL)
        }

        return removedDirectoryURLs
    }

    private static func collectDayDirectoryURLs(
        in baseDirectoryURL: URL,
        fileManager: FileManager,
        calendar: Calendar
    ) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var dayDirectoryURLs: [URL] = []
        for case let candidateURL as URL in enumerator {
            let resourceValues = try candidateURL.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues.isDirectory ?? false
            guard isDirectory else {
                continue
            }

            let hasDayDate = parseDayDate(from: candidateURL, calendar: calendar) != nil
            if hasDayDate {
                dayDirectoryURLs.append(candidateURL)
            }
        }

        return dayDirectoryURLs
    }

    private static func parseDayDate(from dayDirectoryURL: URL, calendar: Calendar) -> Date? {
        let pathComponents = Array(dayDirectoryURL.pathComponents.suffix(3))
        guard pathComponents.count == 3 else {
            return nil
        }

        guard
            let year = Int(pathComponents[0]),
            let month = Int(pathComponents[1]),
            let day = Int(pathComponents[2])
        else {
            return nil
        }

        var dayDateComponents = DateComponents()
        dayDateComponents.year = year
        dayDateComponents.month = month
        dayDateComponents.day = day
        return calendar.date(from: dayDateComponents)
    }
}
