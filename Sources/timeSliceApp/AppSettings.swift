import Foundation
#if canImport(TimeSliceCore)
import TimeSliceCore
#endif

enum AppSettingsKey {
    static let launchAtLoginEnabled = "general.launchAtLogin"
    static let startCaptureOnAppLaunchEnabled = "general.startCaptureOnAppLaunch"
    static let captureIntervalSeconds = "capture.intervalSeconds"
    static let captureMinimumTextLength = "capture.minimumTextLength"
    static let captureShouldSaveImages = "capture.shouldSaveImages"
    static let reportCLICommand = "report.cliCommand"
    static let reportCLIArguments = "report.cliArguments"
    static let reportCLITimeoutSeconds = "report.cliTimeoutSeconds"
    static let reportTargetDayOffset = "report.targetDayOffset"
    static let reportAutoGenerationEnabled = "report.autoGenerationEnabled"
    static let reportAutoGenerationHour = "report.autoGenerationHour"
    static let reportAutoGenerationMinute = "report.autoGenerationMinute"
    static let reportPromptTemplate = "report.promptTemplate"
}

enum AppSettingsResolver {
    static func resolveLaunchAtLoginEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.launchAtLoginEnabled) != nil
        return hasValue ? userDefaults.bool(forKey: AppSettingsKey.launchAtLoginEnabled) : false
    }

    static func resolveCaptureIntervalSeconds(userDefaults: UserDefaults = .standard) -> TimeInterval {
        let configuredInterval = userDefaults.double(forKey: AppSettingsKey.captureIntervalSeconds)
        return configuredInterval > 0 ? configuredInterval : 60
    }

    static func resolveStartCaptureOnAppLaunchEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.startCaptureOnAppLaunchEnabled) != nil
        return hasValue ? userDefaults.bool(forKey: AppSettingsKey.startCaptureOnAppLaunchEnabled) : false
    }

    static func resolveMinimumTextLength(userDefaults: UserDefaults = .standard) -> Int {
        let configuredLength = userDefaults.integer(forKey: AppSettingsKey.captureMinimumTextLength)
        return configuredLength > 0 ? configuredLength : 10
    }

    static func resolveShouldSaveImages(userDefaults: UserDefaults = .standard) -> Bool {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.captureShouldSaveImages) != nil
        return hasValue ? userDefaults.bool(forKey: AppSettingsKey.captureShouldSaveImages) : true
    }

    static func resolveReportCommand(userDefaults: UserDefaults = .standard) -> String {
        let configuredCommand = userDefaults.string(forKey: AppSettingsKey.reportCLICommand)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configuredCommand, configuredCommand.isEmpty == false else {
            return "gemini"
        }
        return configuredCommand
    }

    static func resolveReportArguments(userDefaults: UserDefaults = .standard) -> [String] {
        let argumentsText = userDefaults.string(forKey: AppSettingsKey.reportCLIArguments) ?? "-p"
        return parseCLIArguments(argumentsText)
    }

    static func resolveReportTimeoutSeconds(userDefaults: UserDefaults = .standard) -> TimeInterval {
        let configuredTimeoutSeconds = userDefaults.integer(forKey: AppSettingsKey.reportCLITimeoutSeconds)
        guard configuredTimeoutSeconds > 0 else {
            return 300
        }
        let clampedTimeoutSeconds = min(max(configuredTimeoutSeconds, 30), 3600)
        return TimeInterval(clampedTimeoutSeconds)
    }

    static func resolveReportGenerationConfiguration(
        userDefaults: UserDefaults = .standard
    ) -> ReportGenerationConfiguration {
        ReportGenerationConfiguration(
            command: resolveReportCommand(userDefaults: userDefaults),
            arguments: resolveReportArguments(userDefaults: userDefaults),
            timeoutSeconds: resolveReportTimeoutSeconds(userDefaults: userDefaults),
            promptTemplate: resolveReportPromptTemplate(userDefaults: userDefaults)
        )
    }

    static func resolveReportTargetDate(
        baseDate: Date = Date(),
        calendar: Calendar = .current,
        userDefaults: UserDefaults = .standard
    ) -> Date {
        let dayOffset = userDefaults.integer(forKey: AppSettingsKey.reportTargetDayOffset)
        return calendar.date(byAdding: .day, value: dayOffset, to: baseDate) ?? baseDate
    }

    static func resolveReportAutoGenerationEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.reportAutoGenerationEnabled) != nil
        return hasValue ? userDefaults.bool(forKey: AppSettingsKey.reportAutoGenerationEnabled) : false
    }

    static func resolveReportAutoGenerationHour(userDefaults: UserDefaults = .standard) -> Int {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.reportAutoGenerationHour) != nil
        guard hasValue else {
            return 18
        }
        let configuredHour = userDefaults.integer(forKey: AppSettingsKey.reportAutoGenerationHour)
        return min(max(configuredHour, 0), 23)
    }

    static func resolveReportAutoGenerationMinute(userDefaults: UserDefaults = .standard) -> Int {
        let hasValue = userDefaults.object(forKey: AppSettingsKey.reportAutoGenerationMinute) != nil
        guard hasValue else {
            return 0
        }
        let configuredMinute = userDefaults.integer(forKey: AppSettingsKey.reportAutoGenerationMinute)
        return min(max(configuredMinute, 0), 59)
    }

    private static func parseCLIArguments(_ argumentsText: String) -> [String] {
        argumentsText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    static func resolveReportPromptTemplate(userDefaults: UserDefaults = .standard) -> String? {
        let configuredTemplate = userDefaults.string(forKey: AppSettingsKey.reportPromptTemplate)
        guard let configuredTemplate else {
            return nil
        }
        let trimmedTemplate = configuredTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTemplate.isEmpty ? nil : configuredTemplate
    }
}
