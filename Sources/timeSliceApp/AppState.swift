import Foundation
import Observation
import ServiceManagement
import UserNotifications
import Carbon
#if canImport(TimeSliceCore)
import TimeSliceCore
#endif

@MainActor
@Observable
final class AppState {
    private struct CaptureRuntimeSettings: Equatable {
        let captureIntervalSeconds: TimeInterval
        let minimumTextLength: Int
        let shouldSaveImages: Bool
        let excludedApplications: [String]

        var schedulerConfiguration: CaptureSchedulerConfiguration {
            CaptureSchedulerConfiguration(
                captureIntervalSeconds: captureIntervalSeconds,
                minimumTextLength: minimumTextLength,
                shouldSaveImages: shouldSaveImages,
                excludedApplications: excludedApplications
            )
        }
    }

    private let userDefaults: UserDefaults
    private let dataStore: DataStore
    private let imageStore: ImageStore
    private let reportGenerator: ReportGenerator
    private let reportScheduler: ReportScheduler
    private let reportNotificationManager: ReportNotificationManager
    private let duplicateDetector: DuplicateDetector
    private let screenCaptureManager: ScreenCaptureManager
    private let ocrManager: OCRManager
    private let globalHotKeyManager: GlobalHotKeyManager

    private var captureScheduler: CaptureScheduler?
    private var recordCountRefreshTask: Task<Void, Never>?
    private var reportSchedulerRefreshTask: Task<Void, Never>?
    private var lastNotifiedScheduledReportFilePath: String?
    private var userDefaultsDidChangeObserver: NSObjectProtocol?
    private var appliedCaptureSettings: CaptureRuntimeSettings?

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
        self.reportNotificationManager = ReportNotificationManager()
        let resolvedTimeSlots = AppSettingsResolver.resolveReportTimeSlots(userDefaults: userDefaults)
        self.reportScheduler = ReportScheduler(
            reportGenerator: createdReportGenerator,
            generationConfigurationProvider: { [userDefaults] timeSlot in
                var config = AppSettingsResolver.resolveReportGenerationConfiguration(userDefaults: userDefaults)
                if let timeSlot {
                    config = config.withOutputFileName(timeSlot.outputFileName)
                }
                return config
            },
            reportTargetDateProvider: { [userDefaults] in
                AppSettingsResolver.resolveReportTargetDate(userDefaults: userDefaults)
            },
            timeSlotsProvider: { [userDefaults] in
                AppSettingsResolver.resolveReportTimeSlots(userDefaults: userDefaults)
            },
            isEnabled: AppSettingsResolver.resolveReportAutoGenerationEnabled(userDefaults: userDefaults),
            hour: AppSettingsResolver.resolveReportAutoGenerationHour(userDefaults: userDefaults),
            minute: AppSettingsResolver.resolveReportAutoGenerationMinute(userDefaults: userDefaults),
            timeSlots: resolvedTimeSlots
        )
        self.duplicateDetector = DuplicateDetector()
        self.screenCaptureManager = ScreenCaptureManager()
        self.ocrManager = OCRManager()
        self.globalHotKeyManager = GlobalHotKeyManager()
        reportNotificationManager.configureIfNeeded()
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
        configureCaptureNowGlobalHotKey()
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

    func performSingleCaptureCycle(captureTrigger: CaptureTrigger = .scheduled) async {
        let scheduler = buildCaptureSchedulerIfNeeded()
        let cycleOutcome = await scheduler.performCaptureCycle(captureTrigger: captureTrigger)
        let cycleOutcomeMessage = makeOutcomeMessage(from: cycleOutcome)
        let cycleOutcomeNotificationMessage = makeNotificationMessage(from: cycleOutcome)
        let cycleOutcomeWindowTitle = resolveCaptureWindowTitle(from: cycleOutcome)
        lastCaptureResultMessage = cycleOutcomeMessage
        await refreshTodayRecordCount()
        if captureTrigger == .manual {
            await reportNotificationManager.postCaptureCompletedNotification(
                resultMessage: cycleOutcomeNotificationMessage,
                windowTitle: cycleOutcomeWindowTitle
            )
        }
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
                minute: AppSettingsResolver.resolveReportAutoGenerationMinute(userDefaults: userDefaults),
                timeSlots: AppSettingsResolver.resolveReportTimeSlots(userDefaults: userDefaults)
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
            await reportNotificationManager.postReportGeneratedNotification(
                reportFileURL: generatedReport.reportFileURL,
                sourceRecordCount: generatedReport.sourceRecordCount,
                generationSource: .manual
            )
        } catch {
            lastReportResultMessage = L10n.format("message.report.failed", error.localizedDescription)
        }
    }

    func generateReportForTimeSlot(_ timeSlot: ReportTimeSlot) async {
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
            var generationConfiguration = AppSettingsResolver.resolveReportGenerationConfiguration()
            generationConfiguration = generationConfiguration.withOutputFileName(timeSlot.outputFileName)
            let targetReportDate = AppSettingsResolver.resolveReportTargetDate()
            let timeRange = timeSlot.toTimeRange()
            let generatedReport = try await Task.detached(priority: .userInitiated) {
                try await localReportGenerator.generateReport(
                    on: targetReportDate,
                    configuration: generationConfiguration,
                    timeRange: timeRange
                )
            }.value

            lastGeneratedReportURL = generatedReport.reportFileURL
            lastReportResultMessage = L10n.format(
                "message.report.saved",
                generatedReport.reportFileURL.lastPathComponent,
                generatedReport.sourceRecordCount
            )
            await reportNotificationManager.postReportGeneratedNotification(
                reportFileURL: generatedReport.reportFileURL,
                sourceRecordCount: generatedReport.sourceRecordCount,
                generationSource: .manual
            )
        } catch {
            lastReportResultMessage = L10n.format("message.report.failed", error.localizedDescription)
        }
    }

    private func buildCaptureSchedulerIfNeeded() -> CaptureScheduler {
        if let captureScheduler {
            return captureScheduler
        }

        let resolvedCaptureSettings = resolveCaptureRuntimeSettings()

        let createdScheduler = CaptureScheduler(
            screenCapturer: screenCaptureManager,
            textRecognizer: ocrManager,
            duplicateDetector: duplicateDetector,
            dataStore: dataStore,
            imageStore: imageStore,
            configuration: resolvedCaptureSettings.schedulerConfiguration
        )
        captureScheduler = createdScheduler
        appliedCaptureSettings = resolvedCaptureSettings
        return createdScheduler
    }

    private func resolveCaptureRuntimeSettings() -> CaptureRuntimeSettings {
        CaptureRuntimeSettings(
            captureIntervalSeconds: AppSettingsResolver.resolveCaptureIntervalSeconds(userDefaults: userDefaults),
            minimumTextLength: AppSettingsResolver.resolveMinimumTextLength(userDefaults: userDefaults),
            shouldSaveImages: AppSettingsResolver.resolveShouldSaveImages(userDefaults: userDefaults),
            excludedApplications: AppSettingsResolver.resolveExcludedApplications(userDefaults: userDefaults)
        )
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
        await notifyIfNeededForScheduledReport(schedulerState.lastResult)
    }

    private func notifyIfNeededForScheduledReport(_ schedulerResult: ReportSchedulerResult?) async {
        guard case let .succeeded(generatedReport)? = schedulerResult else {
            return
        }

        let reportFilePath = generatedReport.reportFileURL.path
        guard reportFilePath != lastNotifiedScheduledReportFilePath else {
            return
        }
        lastNotifiedScheduledReportFilePath = reportFilePath

        await reportNotificationManager.postReportGeneratedNotification(
            reportFileURL: generatedReport.reportFileURL,
            sourceRecordCount: generatedReport.sourceRecordCount,
            generationSource: .scheduled
        )
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

    private func makeNotificationMessage(from cycleOutcome: CaptureCycleOutcome) -> String {
        switch cycleOutcome {
        case let .saved(captureRecord):
            return captureRecord.applicationName
        case let .skipped(captureSkipReason):
            return localizedCaptureSkipReason(captureSkipReason)
        case let .failed(errorDescription):
            return errorDescription
        }
    }

    private func resolveCaptureWindowTitle(from cycleOutcome: CaptureCycleOutcome) -> String? {
        guard case let .saved(captureRecord) = cycleOutcome else {
            return nil
        }
        return captureRecord.windowTitle
    }

    private func makeSchedulerStatusMessage(from schedulerState: ReportSchedulerState) -> String {
        guard schedulerState.isEnabled else {
            return L10n.string("message.scheduler.disabled")
        }

        var messageParts = [String]()
        if let nextExecutionDate = schedulerState.nextExecutionDate {
            var nextMessage = L10n.format(
                "message.scheduler.next", Self.reportScheduleDateFormatter.string(from: nextExecutionDate)
            )
            if let slotLabel = schedulerState.nextTimeSlotLabel {
                nextMessage += " (\(slotLabel))"
            }
            messageParts.append(nextMessage)
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

    private func configureCaptureNowGlobalHotKey() {
        globalHotKeyManager.onHotKeyPressed = { [weak self] in
            guard let self else {
                return
            }
            Task { @MainActor in
                await self.performSingleCaptureCycle(captureTrigger: .manual)
            }
        }
        refreshCaptureNowGlobalHotKeyRegistration()
        startUserDefaultsObservationForSettingsChanges()
    }

    private func startUserDefaultsObservationForSettingsChanges() {
        userDefaultsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: userDefaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.refreshCaptureNowGlobalHotKeyRegistration()
                await self.refreshCaptureSchedulerForUpdatedSettings()
            }
        }
    }

    private func refreshCaptureSchedulerForUpdatedSettings() async {
        let resolvedCaptureSettings = resolveCaptureRuntimeSettings()
        guard resolvedCaptureSettings != appliedCaptureSettings else {
            return
        }
        appliedCaptureSettings = resolvedCaptureSettings

        guard isCapturing else {
            return
        }

        if let captureScheduler {
            await captureScheduler.stop()
        }
        captureScheduler = nil

        let scheduler = buildCaptureSchedulerIfNeeded()
        await scheduler.start()
    }

    private func refreshCaptureNowGlobalHotKeyRegistration() {
        let captureNowShortcut = AppSettingsResolver.resolveCaptureNowShortcutConfiguration(userDefaults: userDefaults)
        globalHotKeyManager.updateRegistration(captureNowShortcut)
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

private final class GlobalHotKeyManager {
    var onHotKeyPressed: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeyRef: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: 0x5453484B, id: 1)

    init() {
        installHotKeyEventHandlerIfNeeded()
    }

    deinit {
        unregisterHotKeyIfNeeded()
        removeHotKeyEventHandlerIfNeeded()
    }

    func updateRegistration(_ shortcutConfiguration: CaptureNowShortcutConfiguration?) {
        unregisterHotKeyIfNeeded()

        guard
            let shortcutConfiguration,
            let keyCode = shortcutConfiguration.keyCode
        else {
            return
        }

        let carbonModifiers = resolveCarbonModifiers(shortcutConfiguration.modifiersRawValue)
        guard keyCode >= 0 else {
            return
        }

        var createdHotKeyRef: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &createdHotKeyRef
        )
        guard registrationStatus == noErr else {
            return
        }
        registeredHotKeyRef = createdHotKeyRef
    }

    fileprivate func handleHotKeyPressedEvent(_ eventRef: EventRef?) -> OSStatus {
        guard let eventRef else {
            return OSStatus(eventNotHandledErr)
        }

        var pressedHotKeyID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &pressedHotKeyID
        )
        guard parameterStatus == noErr else {
            return parameterStatus
        }
        guard pressedHotKeyID.signature == hotKeyID.signature, pressedHotKeyID.id == hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        onHotKeyPressed?()
        return noErr
    }

    private func installHotKeyEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var hotKeyPressedEventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installationStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            captureNowGlobalHotKeyEventHandler,
            1,
            &hotKeyPressedEventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        guard installationStatus == noErr else {
            return
        }
    }

    private func removeHotKeyEventHandlerIfNeeded() {
        guard let eventHandlerRef else {
            return
        }
        RemoveEventHandler(eventHandlerRef)
        self.eventHandlerRef = nil
    }

    private func unregisterHotKeyIfNeeded() {
        guard let registeredHotKeyRef else {
            return
        }
        UnregisterEventHotKey(registeredHotKeyRef)
        self.registeredHotKeyRef = nil
    }

    private func resolveCarbonModifiers(_ shortcutModifiersRawValue: Int) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if shortcutModifiersRawValue & 16 != 0 {
            carbonModifiers |= UInt32(cmdKey)
        }
        if shortcutModifiersRawValue & 8 != 0 {
            carbonModifiers |= UInt32(optionKey)
        }
        if shortcutModifiersRawValue & 4 != 0 {
            carbonModifiers |= UInt32(controlKey)
        }
        if shortcutModifiersRawValue & 2 != 0 {
            carbonModifiers |= UInt32(shiftKey)
        }
        return carbonModifiers
    }
}

private func captureNowGlobalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        return OSStatus(eventNotHandledErr)
    }
    let hotKeyManager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    return hotKeyManager.handleHotKeyPressedEvent(eventRef)
}

private enum ReportGenerationSource {
    case manual
    case scheduled
}

enum ReportNotificationUserInfoKey {
    static let reportFilePath = "reportFilePath"
}

enum ReportFileOpeningExecutor {
    static func executeOpenCommand(reportFilePath: String) {
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = [reportFilePath]
        do {
            try openProcess.run()
        } catch {
            // Ignore open-command failures.
        }
    }
}

@MainActor
private final class ReportNotificationManager {
    private let notificationCenter: UNUserNotificationCenter
    private var hasConfigured = false
    private var isNotificationAuthorized = false

    init() {
        notificationCenter = UNUserNotificationCenter.current()
    }

    func configureIfNeeded() {
        guard hasConfigured == false else {
            return
        }
        hasConfigured = true

        Task { [weak self] in
            guard let self else {
                return
            }
            await refreshAuthorizationState()
        }
    }

    func postReportGeneratedNotification(
        reportFileURL: URL,
        sourceRecordCount: Int,
        generationSource: ReportGenerationSource
    ) async {
        await refreshAuthorizationState()
        guard isNotificationAuthorized else {
            return
        }

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = resolveNotificationTitle(for: generationSource)
        notificationContent.body = L10n.format(
            "notification.report.body",
            reportFileURL.lastPathComponent,
            sourceRecordCount
        )
        notificationContent.userInfo = [ReportNotificationUserInfoKey.reportFilePath: reportFileURL.path]
        notificationContent.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: "report-generated-\(UUID().uuidString)",
            content: notificationContent,
            trigger: nil
        )
        do {
            try await notificationCenter.add(notificationRequest)
        } catch {
            // Ignore notification submission failures to avoid blocking report generation.
        }
    }

    func postCaptureCompletedNotification(resultMessage: String, windowTitle: String?) async {
        await refreshAuthorizationState()
        guard isNotificationAuthorized else {
            return
        }

        let resolvedWindowTitle: String
        if let windowTitle, windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            resolvedWindowTitle = windowTitle
        } else {
            resolvedWindowTitle = L10n.string("notification.capture.value.window_title_unavailable")
        }
        let captureDetailMessage = L10n.format("notification.capture.body.window_title", resolvedWindowTitle)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = L10n.string("notification.capture.title.manual")
        notificationContent.body = [resultMessage, captureDetailMessage].joined(separator: "\n")
        notificationContent.sound = .default

        let notificationRequest = UNNotificationRequest(
            identifier: "capture-completed-\(UUID().uuidString)",
            content: notificationContent,
            trigger: nil
        )
        do {
            try await notificationCenter.add(notificationRequest)
        } catch {
            // Ignore notification submission failures to avoid blocking capture flow.
        }
    }

    private func resolveNotificationTitle(for generationSource: ReportGenerationSource) -> String {
        switch generationSource {
        case .manual:
            return L10n.string("notification.report.title.manual")
        case .scheduled:
            return L10n.string("notification.report.title.scheduled")
        }
    }

    private func refreshAuthorizationState() async {
        let notificationSettings = await notificationCenter.notificationSettings()
        switch notificationSettings.authorizationStatus {
        case .authorized, .provisional:
            isNotificationAuthorized = true
        case .notDetermined:
            do {
                isNotificationAuthorized = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            } catch {
                isNotificationAuthorized = false
            }
        default:
            isNotificationAuthorized = false
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
