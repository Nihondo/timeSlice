import Foundation

/// Stores OCR capture records as JSON files under date-based directories.
public struct DataStore: @unchecked Sendable {
    public let textRetentionDays: Int

    private let pathResolver: StoragePathResolver
    private let fileManager: FileManager
    private let calendar: Calendar
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(
        pathResolver: StoragePathResolver,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        textRetentionDays: Int = 30
    ) {
        self.pathResolver = pathResolver
        self.fileManager = fileManager
        self.calendar = calendar
        self.textRetentionDays = textRetentionDays

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.jsonEncoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder
    }

    /// Saves one capture record and returns the saved JSON file location.
    @discardableResult
    public func saveRecord(_ record: CaptureRecord) throws -> URL {
        let directoryURL = pathResolver.dataDirectoryURL(for: record.capturedAt)
        try createDirectoryIfNeeded(at: directoryURL)

        let fileURL = directoryURL.appendingPathComponent(pathResolver.buildRecordFileName(for: record))
        let recordData = try jsonEncoder.encode(record)
        try recordData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Loads records for one day, optionally filtered by time range, sorted by capture timestamp.
    public func loadRecords(on date: Date, timeRange: ReportTimeRange? = nil) throws -> [CaptureRecord] {
        let directoryURL = pathResolver.dataDirectoryURL(for: date)
        let isDirectoryPresent = fileManager.fileExists(atPath: directoryURL.path)
        guard isDirectoryPresent else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let jsonURLs = fileURLs
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var loadedRecords: [CaptureRecord] = []
        loadedRecords.reserveCapacity(jsonURLs.count)
        for jsonURL in jsonURLs {
            let jsonData = try Data(contentsOf: jsonURL)
            let captureRecord = try jsonDecoder.decode(CaptureRecord.self, from: jsonData)
            loadedRecords.append(captureRecord)
        }

        let sortedRecords = loadedRecords.sorted { $0.capturedAt < $1.capturedAt }
        guard let timeRange else {
            return sortedRecords
        }
        return sortedRecords.filter { timeRange.contains($0.capturedAt, calendar: calendar) }
    }

    /// Deletes data directories older than retention period and returns removed directories.
    @discardableResult
    public func cleanupExpiredData(referenceDate: Date) throws -> [URL] {
        let dataRootDirectoryURL = pathResolver.rootDirectoryURL
            .appendingPathComponent("data", isDirectory: true)
        let isDataRootPresent = fileManager.fileExists(atPath: dataRootDirectoryURL.path)
        guard isDataRootPresent else {
            return []
        }

        guard let cutoffDate = calendar.date(byAdding: .day, value: -textRetentionDays, to: referenceDate)
        else {
            return []
        }

        let dayCutoffDate = calendar.startOfDay(for: cutoffDate)
        let dayDirectoryURLs = try collectDayDirectoryURLs(baseDirectoryURL: dataRootDirectoryURL)
        var removedDirectoryURLs: [URL] = []

        for dayDirectoryURL in dayDirectoryURLs {
            guard let dayDate = parseDayDate(from: dayDirectoryURL) else {
                continue
            }
            let isExpiredDirectory = dayDate < dayCutoffDate
            guard isExpiredDirectory else {
                continue
            }

            try fileManager.removeItem(at: dayDirectoryURL)
            removedDirectoryURLs.append(dayDirectoryURL)
        }

        return removedDirectoryURLs
    }

    private func createDirectoryIfNeeded(at directoryURL: URL) throws {
        let isDirectoryPresent = fileManager.fileExists(atPath: directoryURL.path)
        guard isDirectoryPresent == false else {
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func collectDayDirectoryURLs(baseDirectoryURL: URL) throws -> [URL] {
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

            let isDayDirectory = parseDayDate(from: candidateURL) != nil
            if isDayDirectory {
                dayDirectoryURLs.append(candidateURL)
            }
        }

        return dayDirectoryURLs
    }

    private func parseDayDate(from dayDirectoryURL: URL) -> Date? {
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
