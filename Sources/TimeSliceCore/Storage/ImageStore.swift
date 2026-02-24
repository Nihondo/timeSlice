import Foundation

/// Persists screenshot image files and cleans old image directories.
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

    /// Saves screenshot image data and returns the saved file location.
    @discardableResult
    public func saveImageData(
        _ imageData: Data,
        capturedAt: Date,
        recordID: UUID,
        imageFormat: CaptureImageFormat
    ) throws -> URL {
        let directoryURL = pathResolver.imageDirectoryURL(for: capturedAt)
        try StorageMaintenance.ensureDirectoryExists(at: directoryURL, fileManager: fileManager)

        let fileName = pathResolver.buildImageFileName(
            capturedAt: capturedAt,
            recordID: recordID,
            imageFormat: imageFormat
        )
        let fileURL = directoryURL.appendingPathComponent(fileName)
        try imageData.write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Deletes image directories older than retention period and returns removed directories.
    @discardableResult
    public func cleanupExpiredImages(referenceDate: Date) throws -> [URL] {
        let imageRootDirectoryURL = pathResolver.rootDirectoryURL
            .appendingPathComponent("images", isDirectory: true)
        return try StorageMaintenance.cleanupExpiredDayDirectories(
            in: imageRootDirectoryURL,
            retentionDays: imageRetentionDays,
            referenceDate: referenceDate,
            fileManager: fileManager,
            calendar: calendar
        )
    }
}
