import Foundation

/// Runtime parameters for one report generation execution.
public struct ReportGenerationConfiguration: Sendable {
    public let command: String
    public let arguments: [String]
    public let timeoutSeconds: TimeInterval
    public let outputFileName: String
    public let outputDirectoryURL: URL?
    public let promptTemplate: String?

    public init(
        command: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 300,
        outputFileName: String = "report.md",
        outputDirectoryURL: URL? = nil,
        promptTemplate: String? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
        self.outputFileName = outputFileName
        self.outputDirectoryURL = outputDirectoryURL
        self.promptTemplate = promptTemplate
    }

    /// Returns a copy with a different output file name.
    public func withOutputFileName(_ newOutputFileName: String) -> ReportGenerationConfiguration {
        ReportGenerationConfiguration(
            command: command,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            outputFileName: newOutputFileName,
            outputDirectoryURL: outputDirectoryURL,
            promptTemplate: promptTemplate
        )
    }
}

/// Generated report payload and saved file location.
public struct GeneratedReport: Sendable {
    public let reportDate: Date
    public let reportFileURL: URL
    public let markdownText: String
    public let sourceRecordCount: Int
    public let timeSlotLabel: String?

    public init(
        reportDate: Date,
        reportFileURL: URL,
        markdownText: String,
        sourceRecordCount: Int,
        timeSlotLabel: String? = nil
    ) {
        self.reportDate = reportDate
        self.reportFileURL = reportFileURL
        self.markdownText = markdownText
        self.sourceRecordCount = sourceRecordCount
        self.timeSlotLabel = timeSlotLabel
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
        configuration: ReportGenerationConfiguration,
        timeRange: ReportTimeRange? = nil
    ) async throws -> GeneratedReport {
        let dailyRecords = try dataStore.loadRecords(on: reportDate, timeRange: timeRange)
        let relativeJSONGlobPaths = [buildRelativeJSONGlobPath(for: reportDate)]
        return try await generateReportFromRecords(
            dailyRecords,
            reportDate: reportDate,
            configuration: configuration,
            relativeJSONGlobPaths: relativeJSONGlobPaths,
            timeRangeLabel: timeRange?.label
        )
    }

    /// Generates a report for a specific time slot, supporting cross-midnight slots.
    public func generateReport(
        for slot: ReportTimeSlot,
        targetDate: Date,
        configuration: ReportGenerationConfiguration
    ) async throws -> GeneratedReport {
        let overflowDate = slot.executionIsNextDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: targetDate)
            : nil
        var relativeJSONGlobPaths = [buildRelativeJSONGlobPath(for: targetDate)]
        if let overflowDate {
            relativeJSONGlobPaths.append(buildRelativeJSONGlobPath(for: overflowDate))
        }
        let dailyRecords = try dataStore.loadRecordsForSlot(
            primaryDate: targetDate,
            primaryTimeRange: slot.primaryDayTimeRange,
            overflowDate: overflowDate,
            overflowTimeRange: slot.overflowDayTimeRange
        )
        return try await generateReportFromRecords(
            dailyRecords,
            reportDate: targetDate,
            configuration: configuration,
            relativeJSONGlobPaths: relativeJSONGlobPaths,
            timeRangeLabel: slot.timeRangeLabel
        )
    }

    private func generateReportFromRecords(
        _ records: [CaptureRecord],
        reportDate: Date,
        configuration: ReportGenerationConfiguration,
        relativeJSONGlobPaths: [String],
        timeRangeLabel: String?
    ) async throws -> GeneratedReport {
        let runTimestamp = Date()
        var promptText: String?
        var outputText: String?

        do {
            guard records.isEmpty == false else {
                throw ReportGenerationError.noRecords(reportDate)
            }

            let dataRootDirectoryURL = pathResolver.rootDirectoryURL
                .appendingPathComponent("data", isDirectory: true)

            let preparedPromptText = promptBuilder.buildDailyReportPrompt(
                date: reportDate,
                relativeJSONGlobPaths: relativeJSONGlobPaths,
                sourceRecordCount: records.count,
                customTemplate: configuration.promptTemplate,
                timeRangeLabel: timeRangeLabel
            )
            promptText = preparedPromptText

            let markdownText = try await cliExecutor.execute(
                command: configuration.command,
                arguments: configuration.arguments,
                input: preparedPromptText,
                timeoutSeconds: configuration.timeoutSeconds,
                currentDirectoryURL: dataRootDirectoryURL
            )
            outputText = markdownText

            let normalizedMarkdownText = markdownText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedMarkdownText.isEmpty == false else {
                throw ReportGenerationError.emptyReportContent
            }

            let reportFileURL = try saveReportMarkdown(
                normalizedMarkdownText,
                date: reportDate,
                outputDirectoryURL: configuration.outputDirectoryURL,
                outputFileName: configuration.outputFileName
            )
            saveLastRunLogIfPossible(
                runTimestamp: runTimestamp,
                reportDate: reportDate,
                configuration: configuration,
                timeRangeLabel: timeRangeLabel,
                promptText: preparedPromptText,
                outputText: normalizedMarkdownText,
                isSuccessful: true,
                errorDescription: nil
            )
            return GeneratedReport(
                reportDate: reportDate,
                reportFileURL: reportFileURL,
                markdownText: normalizedMarkdownText,
                sourceRecordCount: records.count,
                timeSlotLabel: timeRangeLabel
            )
        } catch {
            saveLastRunLogIfPossible(
                runTimestamp: runTimestamp,
                reportDate: reportDate,
                configuration: configuration,
                timeRangeLabel: timeRangeLabel,
                promptText: promptText,
                outputText: resolveLoggedOutputText(from: error, fallbackOutput: outputText),
                isSuccessful: false,
                errorDescription: error.localizedDescription
            )
            throw error
        }
    }

    private func saveReportMarkdown(
        _ markdownText: String,
        date: Date,
        outputDirectoryURL: URL?,
        outputFileName: String
    ) throws -> URL {
        let reportDirectoryURL = resolveReportDirectoryURL(
            date: date,
            outputDirectoryURL: outputDirectoryURL
        )
        try StorageMaintenance.ensureDirectoryExists(at: reportDirectoryURL, fileManager: fileManager)

        let reportFileURL = reportDirectoryURL.appendingPathComponent(outputFileName)
        try saveExistingReportAsBackupIfNeeded(reportFileURL: reportFileURL, fallbackDate: date)
        guard let markdownData = markdownText.data(using: .utf8) else {
            throw ReportGenerationError.emptyReportContent
        }
        try markdownData.write(to: reportFileURL, options: .atomic)
        return reportFileURL
    }

    private func buildRelativeJSONGlobPath(for date: Date) -> String {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let year = dayComponents.year ?? 0
        let month = dayComponents.month ?? 0
        let day = dayComponents.day ?? 0
        return String(format: "./%04d/%02d/%02d/*.json", year, month, day)
    }

    private func resolveReportDirectoryURL(date: Date, outputDirectoryURL: URL?) -> URL {
        guard let outputDirectoryURL else {
            return pathResolver.reportDirectoryURL(for: date)
        }

        let dayComponents = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = dayComponents.year ?? 0
        let month = dayComponents.month ?? 0
        let day = dayComponents.day ?? 0
        return outputDirectoryURL
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
    }

    private func saveExistingReportAsBackupIfNeeded(reportFileURL: URL, fallbackDate: Date) throws {
        guard fileManager.fileExists(atPath: reportFileURL.path) else {
            return
        }

        let sourceFileTimestamp = resolveFileTimestamp(for: reportFileURL) ?? fallbackDate
        let backupFileName = makeBackupFileName(for: sourceFileTimestamp, outputFileName: reportFileURL.lastPathComponent)
        let backupFileURL = makeAvailableBackupFileURL(
            in: reportFileURL.deletingLastPathComponent(),
            preferredFileName: backupFileName
        )
        try fileManager.copyItem(at: reportFileURL, to: backupFileURL)
    }

    private func makeBackupFileName(for date: Date, outputFileName: String) -> String {
        let fileName = outputFileName as NSString
        let fileNameWithoutExtension = fileName.deletingPathExtension
        let fileExtension = fileName.pathExtension
        let dateStamp = makeTimestamp(for: date)
        if fileExtension.isEmpty {
            return "\(fileNameWithoutExtension)-\(dateStamp)"
        }
        return "\(fileNameWithoutExtension)-\(dateStamp).\(fileExtension)"
    }

    private func makeTimestamp(for date: Date) -> String {
        let dateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = dateComponents.year ?? 0
        let month = dateComponents.month ?? 0
        let day = dateComponents.day ?? 0
        let hour = dateComponents.hour ?? 0
        let minute = dateComponents.minute ?? 0
        let second = dateComponents.second ?? 0
        return String(format: "%04d-%02d-%02d-%02d%02d%02d", year, month, day, hour, minute, second)
    }

    private func resolveFileTimestamp(for fileURL: URL) -> Date? {
        guard let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path) else {
            return nil
        }
        return fileAttributes[.modificationDate] as? Date
    }

    private func makeAvailableBackupFileURL(in directoryURL: URL, preferredFileName: String) -> URL {
        let preferredURL = directoryURL.appendingPathComponent(preferredFileName)
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let fileName = preferredFileName as NSString
        let fileNameWithoutExtension = fileName.deletingPathExtension
        let fileExtension = fileName.pathExtension
        var suffix = 1
        while true {
            let candidateFileName: String
            if fileExtension.isEmpty {
                candidateFileName = "\(fileNameWithoutExtension)_\(suffix)"
            } else {
                candidateFileName = "\(fileNameWithoutExtension)_\(suffix).\(fileExtension)"
            }
            let candidateURL = directoryURL.appendingPathComponent(candidateFileName)
            if fileManager.fileExists(atPath: candidateURL.path) == false {
                return candidateURL
            }
            suffix += 1
        }
    }

    private func saveLastRunLogIfPossible(
        runTimestamp: Date,
        reportDate: Date,
        configuration: ReportGenerationConfiguration,
        timeRangeLabel: String?,
        promptText: String?,
        outputText: String?,
        isSuccessful: Bool,
        errorDescription: String?
    ) {
        let reportLastRunLog = ReportLastRunLog(
            executedAt: runTimestamp,
            reportDate: reportDate,
            command: configuration.command,
            arguments: configuration.arguments,
            timeoutSeconds: configuration.timeoutSeconds,
            timeRangeLabel: timeRangeLabel,
            promptText: promptText ?? "",
            outputText: outputText ?? "",
            isSuccessful: isSuccessful,
            errorDescription: errorDescription
        )

        do {
            let logsDirectoryURL = pathResolver.rootDirectoryURL.appendingPathComponent("logs", isDirectory: true)
            if fileManager.fileExists(atPath: logsDirectoryURL.path) == false {
                try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
            }
            let logFileURL = logsDirectoryURL.appendingPathComponent("report-last-run.json")
            let logData = try buildLastRunLogData(reportLastRunLog)
            try logData.write(to: logFileURL, options: .atomic)
        } catch {
            // Ignore log-writing failures to avoid blocking report generation.
        }
    }

    private func buildLastRunLogData(_ reportLastRunLog: ReportLastRunLog) throws -> Data {
        let logEncoder = JSONEncoder()
        logEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        logEncoder.dateEncodingStrategy = .iso8601
        return try logEncoder.encode(reportLastRunLog)
    }

    private func resolveLoggedOutputText(from error: Error, fallbackOutput: String?) -> String? {
        guard let cliExecutorError = error as? CLIExecutorError else {
            return fallbackOutput
        }
        guard case let .executionFailed(_, _, commandOutput) = cliExecutorError else {
            return fallbackOutput
        }
        return commandOutput.isEmpty ? fallbackOutput : commandOutput
    }
}

private struct ReportLastRunLog: Codable {
    let executedAt: Date
    let reportDate: Date
    let command: String
    let arguments: [String]
    let timeoutSeconds: TimeInterval
    let timeRangeLabel: String?
    let promptText: String
    let outputText: String
    let isSuccessful: Bool
    let errorDescription: String?
}
