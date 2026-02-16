import Foundation
import Observation
import ServiceManagement
#if canImport(TimeSliceCore)
import TimeSliceCore
#endif

@MainActor
@Observable
final class AppState {
    private let userDefaults: UserDefaults
    private let dataStore: DataStore
    private let imageStore: ImageStore
    private let reportGenerator: ReportGenerator
    private let reportScheduler: ReportScheduler
    private let duplicateDetector: DuplicateDetector
    private let screenCaptureManager: ScreenCaptureManager
    private let ocrManager: OCRManager

    private var captureScheduler: CaptureScheduler?
    private var recordCountRefreshTask: Task<Void, Never>?
    private var reportSchedulerRefreshTask: Task<Void, Never>?

    var isCapturing = false
    var hasScreenCapturePermission = false
    var todayRecordCount = 0
    var statusMessage = L10n.string("state.stopped")
    var lastCaptureResultMessage = ""
    var isGeneratingReport = false
    var lastReportResultMessage = ""
    var lastScheduledReportMessage = ""
    var lastGeneratedReportURL: URL?
    var isLaunchAtLoginEnabled = false
    var launchAtLoginStatusMessage = ""
    var isStartCaptureOnAppLaunchEnabled = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let rootDirectoryURL = Self.resolveRootDirectoryURL()
        let pathResolver = StoragePathResolver(rootDirectoryURL: rootDirectoryURL)
        let createdDataStore = DataStore(pathResolver: pathResolver)
        let createdImageStore = ImageStore(pathResolver: pathResolver)
        let createdReportGenerator = ReportGenerator(dataStore: createdDataStore, pathResolver: pathResolver)
        self.dataStore = createdDataStore
        self.imageStore = createdImageStore
        self.reportGenerator = createdReportGenerator
        self.reportScheduler = ReportScheduler(
            reportGenerator: createdReportGenerator,
            generationConfigurationProvider: { [userDefaults] in
                AppSettingsResolver.resolveReportGenerationConfiguration(userDefaults: userDefaults)
            },
            reportTargetDateProvider: { [userDefaults] in
                AppSettingsResolver.resolveReportTargetDate(userDefaults: userDefaults)
            },
            isEnabled: AppSettingsResolver.resolveReportAutoGenerationEnabled(userDefaults: userDefaults),
            hour: AppSettingsResolver.resolveReportAutoGenerationHour(userDefaults: userDefaults),
            minute: AppSettingsResolver.resolveReportAutoGenerationMinute(userDefaults: userDefaults)
        )
        self.duplicateDetector = DuplicateDetector()
        self.screenCaptureManager = ScreenCaptureManager()
        self.ocrManager = OCRManager()
        refreshPermissionStatus()
        Task {
            await refreshTodayRecordCount()
        }
        Task {
            await reportScheduler.start()
            await refreshReportSchedulerStatus()
        }
        startReportSchedulerRefreshLoop()
        synchronizeLaunchAtLoginSetting()
        synchronizeStartCaptureOnAppLaunchSetting()
        if isStartCaptureOnAppLaunchEnabled {
            Task {
                await startCapture()
            }
        }
    }

    func toggleCapture() async {
        if isCapturing {
            await stopCapture()
        } else {
            await startCapture()
        }
    }

    func startCapture() async {
        refreshPermissionStatus()
        if hasScreenCapturePermission == false {
            _ = screenCaptureManager.requestScreenCapturePermission()
            refreshPermissionStatus()
            if hasScreenCapturePermission == false {
                statusMessage = L10n.string("state.permission_missing")
                return
            }
        }

        let scheduler = buildCaptureSchedulerIfNeeded()
        await scheduler.start()
        isCapturing = true
        statusMessage = L10n.string("state.capturing")

        startRecordCountRefreshLoop()
        await performSingleCaptureCycle()
    }

    func stopCapture() async {
        guard let captureScheduler else {
            isCapturing = false
            statusMessage = L10n.string("state.stopped")
            return
        }

        await captureScheduler.stop()
        recordCountRefreshTask?.cancel()
        recordCountRefreshTask = nil
        self.captureScheduler = nil
        isCapturing = false
        statusMessage = L10n.string("state.stopped")
    }

    func performSingleCaptureCycle() async {
        let scheduler = buildCaptureSchedulerIfNeeded()
        let cycleOutcome = await scheduler.performCaptureCycle()
        lastCaptureResultMessage = makeOutcomeMessage(from: cycleOutcome)
        await refreshTodayRecordCount()
    }

    func refreshTodayRecordCount() async {
        do {
            let localDataStore = dataStore
            let currentDate = Date()
            let recordCount = try await Task.detached(priority: .utility) {
                try localDataStore.loadRecords(on: currentDate).count
            }.value
            todayRecordCount = recordCount
        } catch {
            lastCaptureResultMessage = L10n.format("message.record_count_refresh_failed", error.localizedDescription)
        }
    }

    func refreshPermissionStatus() {
        hasScreenCapturePermission = screenCaptureManager.hasScreenCapturePermission()
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        do {
            try LaunchAtLoginManager.updateRegistration(isEnabled: isEnabled)
            let serviceStatus = applyLaunchAtLoginStateFromSystem()
            switch serviceStatus {
            case .requiresApproval:
                launchAtLoginStatusMessage = L10n.string("message.launch_at_login.requires_approval")
            default:
                launchAtLoginStatusMessage = ""
            }
        } catch {
            _ = applyLaunchAtLoginStateFromSystem()
            launchAtLoginStatusMessage = L10n.format("message.launch_at_login.update_failed", error.localizedDescription)
        }
    }

    func setStartCaptureOnAppLaunchEnabled(_ isEnabled: Bool) {
        isStartCaptureOnAppLaunchEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: AppSettingsKey.startCaptureOnAppLaunchEnabled)
    }

    func updateReportSchedule() {
        Task {
            await reportScheduler.updateSchedule(
                isEnabled: AppSettingsResolver.resolveReportAutoGenerationEnabled(userDefaults: userDefaults),
                hour: AppSettingsResolver.resolveReportAutoGenerationHour(userDefaults: userDefaults),
                minute: AppSettingsResolver.resolveReportAutoGenerationMinute(userDefaults: userDefaults)
            )
            await refreshReportSchedulerStatus()
        }
    }

    func generateDailyReport() async {
        guard isGeneratingReport == false else {
            return
        }

        isGeneratingReport = true
        lastReportResultMessage = L10n.string("message.report.generating")
        defer {
            isGeneratingReport = false
        }

        do {
            let localReportGenerator = reportGenerator
            let generationConfiguration = AppSettingsResolver.resolveReportGenerationConfiguration()
            let targetReportDate = AppSettingsResolver.resolveReportTargetDate()
            let generatedReport = try await Task.detached(priority: .userInitiated) {
                try await localReportGenerator.generateReport(
                    on: targetReportDate,
                    configuration: generationConfiguration
                )
            }.value

            lastGeneratedReportURL = generatedReport.reportFileURL
            lastReportResultMessage = L10n.format(
                "message.report.saved",
                generatedReport.reportFileURL.lastPathComponent,
                generatedReport.sourceRecordCount
            )
        } catch {
            lastReportResultMessage = L10n.format("message.report.failed", error.localizedDescription)
        }
    }

    private func buildCaptureSchedulerIfNeeded() -> CaptureScheduler {
        if let captureScheduler {
            return captureScheduler
        }

        let captureIntervalSeconds = AppSettingsResolver.resolveCaptureIntervalSeconds()
        let minimumTextLength = AppSettingsResolver.resolveMinimumTextLength()
        let shouldSaveImages = AppSettingsResolver.resolveShouldSaveImages()

        let createdScheduler = CaptureScheduler(
            screenCapturer: screenCaptureManager,
            textRecognizer: ocrManager,
            duplicateDetector: duplicateDetector,
            dataStore: dataStore,
            imageStore: imageStore,
            configuration: CaptureSchedulerConfiguration(
                captureIntervalSeconds: captureIntervalSeconds,
                minimumTextLength: minimumTextLength,
                shouldSaveImages: shouldSaveImages
            )
        )
        captureScheduler = createdScheduler
        return createdScheduler
    }

    private func startRecordCountRefreshLoop() {
        recordCountRefreshTask?.cancel()
        recordCountRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else {
                    break
                }
                await self.refreshTodayRecordCount()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
        }
    }

    private func startReportSchedulerRefreshLoop() {
        reportSchedulerRefreshTask?.cancel()
        reportSchedulerRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                guard let self else {
                    break
                }
                await self.refreshReportSchedulerStatus()
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
            }
        }
    }

    private func refreshReportSchedulerStatus() async {
        let schedulerState = await reportScheduler.snapshot()
        lastScheduledReportMessage = makeSchedulerStatusMessage(from: schedulerState)
    }

    private func makeOutcomeMessage(from cycleOutcome: CaptureCycleOutcome) -> String {
        switch cycleOutcome {
        case let .saved(captureRecord):
            return L10n.format("message.capture.saved", captureRecord.applicationName)
        case let .skipped(captureSkipReason):
            return L10n.format("message.capture.skipped", localizedCaptureSkipReason(captureSkipReason))
        case let .failed(errorDescription):
            return L10n.format("message.capture.failed", errorDescription)
        }
    }

    private func makeSchedulerStatusMessage(from schedulerState: ReportSchedulerState) -> String {
        guard schedulerState.isEnabled else {
            return L10n.string("message.scheduler.disabled")
        }

        var messageParts = [String]()
        if let nextExecutionDate = schedulerState.nextExecutionDate {
            messageParts.append(
                L10n.format("message.scheduler.next", Self.reportScheduleDateFormatter.string(from: nextExecutionDate))
            )
        }
        if let lastResult = schedulerState.lastResult {
            messageParts.append(makeLastSchedulerResultMessage(from: lastResult))
        }

        return messageParts.isEmpty ? L10n.string("message.scheduler.enabled") : messageParts.joined(separator: " / ")
    }

    private func makeLastSchedulerResultMessage(from schedulerResult: ReportSchedulerResult) -> String {
        switch schedulerResult {
        case let .succeeded(generatedReport):
            return L10n.format(
                "message.scheduler.last_success",
                generatedReport.reportFileURL.lastPathComponent,
                generatedReport.sourceRecordCount
            )
        case .skippedNoRecords:
            return L10n.string("message.scheduler.last_skipped_no_records")
        case let .failed(errorDescription):
            return L10n.format("message.scheduler.last_failed", errorDescription)
        }
    }

    private func synchronizeLaunchAtLoginSetting() {
        let preferredValue = AppSettingsResolver.resolveLaunchAtLoginEnabled(userDefaults: userDefaults)
        let registeredValue = LaunchAtLoginManager.resolveRegistrationState()

        if preferredValue != registeredValue {
            do {
                try LaunchAtLoginManager.updateRegistration(isEnabled: preferredValue)
            } catch {
                launchAtLoginStatusMessage = L10n.format("message.launch_at_login.sync_failed", error.localizedDescription)
            }
        }

        let serviceStatus = applyLaunchAtLoginStateFromSystem()
        if serviceStatus == .requiresApproval {
            launchAtLoginStatusMessage = L10n.string("message.launch_at_login.requires_approval")
        }
    }

    private func synchronizeStartCaptureOnAppLaunchSetting() {
        isStartCaptureOnAppLaunchEnabled = AppSettingsResolver.resolveStartCaptureOnAppLaunchEnabled(
            userDefaults: userDefaults
        )
    }

    @discardableResult
    private func applyLaunchAtLoginStateFromSystem() -> SMAppService.Status {
        let serviceStatus = LaunchAtLoginManager.resolveServiceStatus()
        isLaunchAtLoginEnabled = LaunchAtLoginManager.resolveRegistrationState(serviceStatus: serviceStatus)
        userDefaults.set(isLaunchAtLoginEnabled, forKey: AppSettingsKey.launchAtLoginEnabled)
        return serviceStatus
    }

    private static func resolveRootDirectoryURL() -> URL {
        let defaultApplicationSupportURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory

        return defaultApplicationSupportURL
            .appendingPathComponent("timeSlice", isDirectory: true)
    }

    private static let reportScheduleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func localizedCaptureSkipReason(_ captureSkipReason: CaptureSkipReason) -> String {
        switch captureSkipReason {
        case .noWindow:
            return L10n.string("capture.skip_reason.no_window")
        case .shortText:
            return L10n.string("capture.skip_reason.short_text")
        case .duplicateText:
            return L10n.string("capture.skip_reason.duplicate_text")
        case .pngEncodingFailed:
            return L10n.string("capture.skip_reason.png_encoding_failed")
        }
    }
}

private enum LaunchAtLoginManager {
    static func resolveServiceStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func resolveRegistrationState() -> Bool {
        resolveRegistrationState(serviceStatus: resolveServiceStatus())
    }

    static func resolveRegistrationState(serviceStatus: SMAppService.Status) -> Bool {
        switch serviceStatus {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    static func updateRegistration(isEnabled: Bool) throws {
        let currentValue = resolveRegistrationState()
        guard currentValue != isEnabled else {
            return
        }

        if isEnabled {
            try SMAppService.mainApp.register()
            return
        }
        try SMAppService.mainApp.unregister()
    }
}
