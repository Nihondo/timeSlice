import Foundation

/// Runtime parameters for one report generation execution.
public struct ReportGenerationConfiguration: Sendable {
    public let command: String
    public let arguments: [String]
    public let timeoutSeconds: TimeInterval
    public let outputFileName: String
    public let promptTemplate: String?

    public init(
        command: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 300,
        outputFileName: String = "report.md",
        promptTemplate: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.outputFileName = outputFileName
        self.promptTemplate = promptTemplate
    }
}

/// Generated report payload and saved file location.
public struct GeneratedReport: Sendable {
    public let reportDate: Date
    public let reportFileURL: URL
    public let markdownText: String
    public let sourceRecordCount: Int

    public init(reportDate: Date, reportFileURL: URL, markdownText: String, sourceRecordCount: Int) {
        self.reportDate = reportDate
        self.reportFileURL = reportFileURL
        self.markdownText = markdownText
        self.sourceRecordCount = sourceRecordCount
    }
}

/// Report generation failure reasons.
public enum ReportGenerationError: LocalizedError {
    case noRecords(Date)
    case emptyReportContent

    public var errorDescription: String? {
        switch self {
        case let .noRecords(date):
            let formatter = DateFormatter()
            formatter.locale = .autoupdatingCurrent
            formatter.dateFormat = "yyyy-MM-dd"
            return String(
                format: NSLocalizedString("error.report.no_records", comment: ""),
                locale: .autoupdatingCurrent,
                formatter.string(from: date)
            )
        case .emptyReportContent:
            return NSLocalizedString("error.report.empty_output", comment: "")
        }
    }
}

/// Generates markdown reports from one-day capture records.
public struct ReportGenerator: @unchecked Sendable {
    private let dataStore: DataStore
    private let pathResolver: StoragePathResolver
    private let promptBuilder: PromptBuilder
    private let cliExecutor: any CLIExecutable
    private let fileManager: FileManager

    public init(
        dataStore: DataStore,
        pathResolver: StoragePathResolver,
        promptBuilder: PromptBuilder = .init(),
        cliExecutor: any CLIExecutable = CLIExecutor(),
        fileManager: FileManager = .default
    ) {
        self.dataStore = dataStore
        self.pathResolver = pathResolver
        self.promptBuilder = promptBuilder
        self.cliExecutor = cliExecutor
        self.fileManager = fileManager
    }

    /// Loads one-day records, calls CLI, and saves markdown under reports directory.
    public func generateReport(
        on reportDate: Date,
        configuration: ReportGenerationConfiguration
    ) async throws -> GeneratedReport {
        let dailyRecords = try dataStore.loadRecords(on: reportDate)
        guard dailyRecords.isEmpty == false else {
            throw ReportGenerationError.noRecords(reportDate)
        }

        let dataRootDirectoryURL = pathResolver.rootDirectoryURL
            .appendingPathComponent("data", isDirectory: true)
        let relativeJSONGlobPath = buildRelativeJSONGlobPath(for: reportDate)
        let promptText = promptBuilder.buildDailyReportPrompt(
            date: reportDate,
            relativeJSONGlobPath: relativeJSONGlobPath,
            sourceRecordCount: dailyRecords.count,
            customTemplate: configuration.promptTemplate
        )
        let markdownText = try await cliExecutor.execute(
            command: configuration.command,
            arguments: configuration.arguments,
            input: promptText,
            timeoutSeconds: configuration.timeoutSeconds,
            currentDirectoryURL: dataRootDirectoryURL
        )
        let normalizedMarkdownText = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedMarkdownText.isEmpty == false else {
            throw ReportGenerationError.emptyReportContent
        }

        let reportFileURL = try saveReportMarkdown(
            normalizedMarkdownText,
            date: reportDate,
            outputFileName: configuration.outputFileName
        )
        return GeneratedReport(
            reportDate: reportDate,
            reportFileURL: reportFileURL,
            markdownText: normalizedMarkdownText,
            sourceRecordCount: dailyRecords.count
        )
    }

    private func saveReportMarkdown(
        _ markdownText: String,
        date: Date,
        outputFileName: String
    ) throws -> URL {
        let reportDirectoryURL = pathResolver.reportDirectoryURL(for: date)
        try createDirectoryIfNeeded(at: reportDirectoryURL)

        let reportFileURL = reportDirectoryURL.appendingPathComponent(outputFileName)
        guard let markdownData = markdownText.data(using: .utf8) else {
            throw ReportGenerationError.emptyReportContent
        }
        try markdownData.write(to: reportFileURL, options: .atomic)
        return reportFileURL
    }

    private func createDirectoryIfNeeded(at directoryURL: URL) throws {
        let hasDirectory = fileManager.fileExists(atPath: directoryURL.path)
        guard hasDirectory == false else {
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func buildRelativeJSONGlobPath(for date: Date) -> String {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let year = dayComponents.year ?? 0
        let month = dayComponents.month ?? 0
        let day = dayComponents.day ?? 0
        return String(format: "./%04d/%02d/%02d/*.json", year, month, day)
    }
}
