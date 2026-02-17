import Foundation
import SwiftUI
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
    static let reportOutputDirectoryPath = "report.outputDirectoryPath"
    static let reportPromptTemplate = "report.promptTemplate"
    static let captureNowShortcutKey = "shortcut.captureNowKey"
    static let captureNowShortcutModifiers = "shortcut.captureNowModifiers"
    static let captureNowShortcutKeyCode = "shortcut.captureNowKeyCode"
}

struct CaptureNowShortcutConfiguration: Equatable {
    let key: String
    let modifiersRawValue: Int
    let keyCode: Int?

    var eventModifiers: EventModifiers {
        CaptureNowShortcutResolver.resolveStoredEventModifiers(modifiersRawValue)
    }

    var displayText: String {
        CaptureNowShortcutResolver.makeDisplayText(key: key, modifiers: eventModifiers)
    }
}

enum CaptureNowShortcutResolver {
    static let allowedModifiers: EventModifiers = [.command, .control, .option, .shift]

    static func resolveConfiguration(
        shortcutKey: String,
        storedModifiersRawValue: Int,
        hasStoredModifiers: Bool,
        storedKeyCode: Int,
        hasStoredKeyCode: Bool
    ) -> CaptureNowShortcutConfiguration? {
        guard let normalizedKey = normalizeStoredKey(shortcutKey) else {
            return nil
        }
        let resolvedModifiersRawValue = resolveModifiersRawValue(
            storedModifiersRawValue: storedModifiersRawValue,
            hasStoredModifiers: hasStoredModifiers,
            hasShortcut: true
        )
        let resolvedKeyCode = hasStoredKeyCode ? storedKeyCode : nil
        return CaptureNowShortcutConfiguration(
            key: normalizedKey,
            modifiersRawValue: resolvedModifiersRawValue,
            keyCode: resolvedKeyCode
        )
    }

    static func resolveStoredEventModifiers(_ modifiersRawValue: Int) -> EventModifiers {
        EventModifiers(rawValue: modifiersRawValue).intersection(allowedModifiers)
    }

    static func makeDisplayText(key: String, modifiers: EventModifiers) -> String {
        modifierSymbols(modifiers: modifiers) + key.uppercased()
    }

    static func normalizeStoredKey(_ key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedKey.first, trimmedKey.count == 1 else {
            return nil
        }

        let normalizedKey = String(firstCharacter).lowercased()
        guard let scalar = normalizedKey.unicodeScalars.first, CharacterSet.controlCharacters.contains(scalar) == false else {
            return nil
        }
        return normalizedKey
    }

    static func resolveModifiersRawValue(
        storedModifiersRawValue: Int,
        hasStoredModifiers: Bool,
        hasShortcut: Bool
    ) -> Int {
        if hasStoredModifiers {
            return Int(resolveStoredEventModifiers(storedModifiersRawValue).rawValue)
        }

        if hasShortcut {
            return Int(EventModifiers.command.rawValue)
        }

        return 0
    }

    private static func modifierSymbols(modifiers: EventModifiers) -> String {
        var symbols = ""
        if modifiers.contains(.control) {
            symbols += "⌃"
        }
        if modifiers.contains(.option) {
            symbols += "⌥"
        }
        if modifiers.contains(.shift) {
            symbols += "⇧"
        }
        if modifiers.contains(.command) {
            symbols += "⌘"
        }
        return symbols
    }
}

enum AppSettingsResolver {
    static func resolveCaptureNowShortcutConfiguration(userDefaults: UserDefaults = .standard) -> CaptureNowShortcutConfiguration? {
        CaptureNowShortcutResolver.resolveConfiguration(
            shortcutKey: userDefaults.string(forKey: AppSettingsKey.captureNowShortcutKey) ?? "",
            storedModifiersRawValue: userDefaults.integer(forKey: AppSettingsKey.captureNowShortcutModifiers),
            hasStoredModifiers: userDefaults.object(forKey: AppSettingsKey.captureNowShortcutModifiers) != nil,
            storedKeyCode: userDefaults.integer(forKey: AppSettingsKey.captureNowShortcutKeyCode),
            hasStoredKeyCode: userDefaults.object(forKey: AppSettingsKey.captureNowShortcutKeyCode) != nil
        )
    }

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
            outputDirectoryURL: resolveReportOutputDirectoryURL(userDefaults: userDefaults),
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

    static func resolveReportOutputDirectoryPath(userDefaults: UserDefaults = .standard) -> String? {
        let configuredPath = userDefaults.string(forKey: AppSettingsKey.reportOutputDirectoryPath)
        guard let configuredPath else {
            return nil
        }
        let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? nil : trimmedPath
    }

    static func resolveReportOutputDirectoryURL(userDefaults: UserDefaults = .standard) -> URL? {
        guard let outputDirectoryPath = resolveReportOutputDirectoryPath(userDefaults: userDefaults) else {
            return nil
        }
        return URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
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
