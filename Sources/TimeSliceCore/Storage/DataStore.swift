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
        try StorageMaintenance.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)

        let fileURL = directoryURL.appendingPathComponent(pathResolver.buildRecordFileName(for: record))
        let recordData = try jsonEncoder.encode(record)
        try recordData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Loads records for one day, optionally filtered by time range, sorted by capture timestamp.
    public func loadRecords(on date: Date, timeRange: ReportTimeRange? = nil) throws -> [CaptureRecord] {
        let sortedRecords = try loadRecordEntries(on: date)
            .map(\.record)
            .sorted { $0.capturedAt < $1.capturedAt }
        guard let timeRange else {
            return sortedRecords
        }
        return sortedRecords.filter { timeRange.contains($0.capturedAt, calendar: calendar) }
    }

    /// Loads one-day viewer artifacts that include JSON path and linked image status.
    public func loadRecordArtifacts(on date: Date) throws -> [CaptureRecordArtifact] {
        let recordEntries = try loadRecordEntries(on: date)
        var artifacts: [CaptureRecordArtifact] = []
        artifacts.reserveCapacity(recordEntries.count)

        for entry in recordEntries {
            let artifact = buildRecordArtifact(record: entry.record, jsonFileURL: entry.jsonURL)
            artifacts.append(artifact)
        }

        return artifacts.sorted { $0.record.capturedAt < $1.record.capturedAt }
    }

    /// Loads records for a time slot that may span across midnight.
    /// Merges records from the primary date and optional overflow (next calendar) date.
    public func loadRecordsForSlot(
        primaryDate: Date,
        primaryTimeRange: ReportTimeRange?,
        overflowDate: Date?,
        overflowTimeRange: ReportTimeRange?
    ) throws -> [CaptureRecord] {
        let primaryRecords = try loadRecords(on: primaryDate, timeRange: primaryTimeRange)
        guard let overflowDate, let overflowTimeRange else {
            return primaryRecords
        }
        let overflowRecords = try loadRecords(on: overflowDate, timeRange: overflowTimeRange)
        return (primaryRecords + overflowRecords).sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Deletes data directories older than retention period and returns removed directories.
    @discardableResult
    public func cleanupExpiredData(referenceDate: Date) throws -> [URL] {
        let dataRootDirectoryURL = pathResolver.rootDirectoryURL
            .appendingPathComponent("data", isDirectory: true)
        return try StorageMaintenance.cleanupExpiredDayDirectories(
            in: dataRootDirectoryURL,
            retentionDays: textRetentionDays,
            referenceDate: referenceDate,
            fileManager: fileManager,
            calendar: calendar
        )
    }

    private func loadRecordEntries(on date: Date) throws -> [(jsonURL: URL, record: CaptureRecord)] {
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

        var recordEntries: [(jsonURL: URL, record: CaptureRecord)] = []
        recordEntries.reserveCapacity(jsonURLs.count)
        for jsonURL in jsonURLs {
            let jsonData = try Data(contentsOf: jsonURL)
            let captureRecord = try jsonDecoder.decode(CaptureRecord.self, from: jsonData)
            recordEntries.append((jsonURL: jsonURL, record: captureRecord))
        }
        return recordEntries
    }

    private func buildRecordArtifact(record: CaptureRecord, jsonFileURL: URL) -> CaptureRecordArtifact {
        guard record.hasImage else {
            return CaptureRecordArtifact(
                record: record,
                jsonFileURL: jsonFileURL,
                imageFileURL: nil,
                imageLinkState: .notCaptured
            )
        }

        let imageFileURL = pathResolver.imageDirectoryURL(for: record.capturedAt)
            .appendingPathComponent(
                pathResolver.buildImageFileName(capturedAt: record.capturedAt, recordID: record.id)
            )
        let isImagePresent = fileManager.fileExists(atPath: imageFileURL.path)
        let imageLinkState: CaptureImageLinkState = isImagePresent ? .available : .missingOrExpired
        return CaptureRecordArtifact(
            record: record,
            jsonFileURL: jsonFileURL,
            imageFileURL: imageFileURL,
            imageLinkState: imageLinkState
        )
    }

}
