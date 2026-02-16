import Foundation

/// Persists screenshot PNG files and cleans old image directories.
public struct ImageStore: @unchecked Sendable {
    public let imageRetentionDays: Int

    private let pathResolver: StoragePathResolver
    private let fileManager: FileManager
    private let calendar: Calendar

    public init(
        pathResolver: StoragePathResolver,
        fileManager: FileManager = .default,
        calendar: Calendar = .current,
        imageRetentionDays: Int = 3
    ) {
        self.pathResolver = pathResolver
        self.fileManager = fileManager
        self.calendar = calendar
        self.imageRetentionDays = imageRetentionDays
    }

    /// Saves screenshot PNG data and returns the saved file location.
    @discardableResult
    public func saveImageData(
        _ imageData: Data,
        capturedAt: Date,
        recordID: UUID
    ) throws -> URL {
        let directoryURL = pathResolver.imageDirectoryURL(for: capturedAt)
        try createDirectoryIfNeeded(at: directoryURL)

        let fileName = pathResolver.buildImageFileName(capturedAt: capturedAt, recordID: recordID)
        let fileURL = directoryURL.appendingPathComponent(fileName)
        try imageData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Deletes image directories older than retention period and returns removed directories.
    @discardableResult
    public func cleanupExpiredImages(referenceDate: Date) throws -> [URL] {
        let imageRootDirectoryURL = pathResolver.rootDirectoryURL
            .appendingPathComponent("images", isDirectory: true)
        let isImageRootPresent = fileManager.fileExists(atPath: imageRootDirectoryURL.path)
        guard isImageRootPresent else {
            return []
        }

        guard let cutoffDate = calendar.date(byAdding: .day, value: -imageRetentionDays, to: referenceDate)
        else {
            return []
        }

        let dayCutoffDate = calendar.startOfDay(for: cutoffDate)
        let dayDirectoryURLs = try collectDayDirectoryURLs(baseDirectoryURL: imageRootDirectoryURL)
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
