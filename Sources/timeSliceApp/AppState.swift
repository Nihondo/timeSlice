import AppKit
import Foundation
import Observation
import ServiceManagement
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
        let imageFormat: CaptureImageFormat
        let excludedApplications: [String]
        let excludedWindowTitles: [String]

        var schedulerConfiguration: CaptureSchedulerConfiguration {
            CaptureSchedulerConfiguration(
                captureIntervalSeconds: captureIntervalSeconds,
                minimumTextLength: minimumTextLength,
                shouldSaveImages: shouldSaveImages,
                imageFormat: imageFormat,
                excludedApplications: excludedApplications,
                excludedWindowTitles: excludedWindowTitles
            )
        }
    }

    private enum ManualReportRequest {
        case daily(targetDate: Date)
        case timeSlot(timeSlot: ReportTimeSlot, targetDate: Date, isSoleEnabledSlot: Bool)
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
    private let manualCaptureCommentPanelPresenter: ManualCaptureCommentPanelPresenter

    private var captureScheduler: CaptureScheduler?
    private var recordCountRefreshTask: Task<Void, Never>?
    private var reportSchedulerRefreshTask: Task<Void, Never>?
    private var lastProcessedScheduledResultSequence: UInt64 = 0
    private var userDefaultsDidChangeObserver: NSObjectProtocol?
    private var appliedCaptureSettings: CaptureRuntimeSettings?
    private var manualCaptureReturnApplication: NSRunningApplication?
    private var hasRequestedAccessibilityPermissionThisSession = false

    var isCapturing = false
    var hasScreenCapturePermission = false
    var hasAccessibilityPermission = false
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
    var captureViewerArtifacts: [CaptureRecordArtifact] = []
    var isLoadingCaptureViewerArtifacts = false
    var captureViewerStatusMessage = ""
    var captureViewerSearchQuery = ""
    var captureViewerSearchRequestSequence: UInt64 = 0

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        AppSettingsResolver.migrateReportSettingsIfNeeded(userDefaults: userDefaults)
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
            generationConfigurationProvider: { [userDefaults] timeSlot, isSoleEnabledSlot in
                AppSettingsResolver.resolveReportGenerationConfigurationForSlot(
                    timeSlot,
                    isSoleEnabledSlot: isSoleEnabledSlot,
                    userDefaults: userDefaults
                )
            },
            isEnabled: AppSettingsResolver.resolveReportAutoGenerationEnabled(userDefaults: userDefaults),
            timeSlots: resolvedTimeSlots
        )
        self.duplicateDetector = DuplicateDetector()
        self.screenCaptureManager = ScreenCaptureManager()
        self.ocrManager = OCRManager()
        self.globalHotKeyManager = GlobalHotKeyManager()
        self.manualCaptureCommentPanelPresenter = ManualCaptureCommentPanelPresenter()
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
            if requestScreenCapturePermission() == false {
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

    func startRectangleCaptureFlow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.manualCaptureCommentPanelPresenter.isPresenting {
                self.manualCaptureCommentPanelPresenter.dismissActivePanelIfNeeded()
                return
            }
            // Wait briefly so the menu bar dropdown closes before screencapture -i launches.
            try? await Task.sleep(for: .milliseconds(300))
            let configuration = resolveCaptureRuntimeSettings().schedulerConfiguration
            let rectangleCapturing = RectangleCaptureScreenCapturing(
                applicationName: L10n.string("rectangle_capture.application_name")
            )
            let scheduler = CaptureScheduler(
                screenCapturer: rectangleCapturing,
                textRecognizer: ocrManager,
                duplicateDetector: duplicateDetector,
                dataStore: dataStore,
                imageStore: imageStore,
                configuration: configuration
            )
            let preparationOutcome = await scheduler.prepareManualCaptureDraft()
            switch preparationOutcome {
            case .skipped, .failed:
                // User cancelled screencapture (Esc) or an error occurred — nothing to show.
                return
            case let .prepared(draft):
                manualCaptureCommentPanelPresenter.present(
                    applicationName: draft.applicationName,
                    windowTitle: draft.windowTitle,
                    onSubmitComment: { [weak self] manualComment in
                        guard let self else { return }
                        Task { @MainActor in
                            let saveOutcome = await scheduler.saveManualCaptureDraft(
                                draft,
                                manualComment: manualComment,
                                captureTrigger: .rectangleCapture
                            )
                            await self.applyCaptureCycleOutcome(saveOutcome, captureTrigger: .rectangleCapture)
                        }
                    },
                    onSearchInViewer: { [weak self] searchQuery in
                        guard let self else { return }
                        Task { @MainActor in
                            self.requestCaptureViewerSearch(searchQuery)
                        }
                    },
                    onCancel: {}
                )
            }
        }
    }

    func startManualCaptureFlow() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.manualCaptureCommentPanelPresenter.isPresenting {
                self.manualCaptureCommentPanelPresenter.dismissActivePanelIfNeeded()
                return
            }
            let frontmostApplication = NSWorkspace.shared.frontmostApplication
            self.manualCaptureReturnApplication = frontmostApplication
            let shouldPromptForAccessibilityPermission = self.hasRequestedAccessibilityPermissionThisSession == false
            let manualCaptureContext = FrontmostSelectionTextResolver.resolveManualCaptureContext(
                from: frontmostApplication,
                shouldPromptForPermission: shouldPromptForAccessibilityPermission
            )
            let manualCaptureApplicationName = resolveManualCaptureApplicationName(from: frontmostApplication)
            self.hasRequestedAccessibilityPermissionThisSession = true
            self.manualCaptureCommentPanelPresenter.present(
                applicationName: manualCaptureApplicationName,
                windowTitle: manualCaptureContext.focusedWindowTitle,
                initialComment: manualCaptureContext.initialComment,
                onSubmitComment: { [weak self] manualComment in
                    guard let self else {
                        return
                    }
                    Task { @MainActor in
                        self.restoreManualCaptureReturnApplicationIfNeeded()
                        await self.performSingleCaptureCycle(
                            captureTrigger: .manual,
                            manualComment: manualComment
                        )
                    }
                },
                onSearchInViewer: { [weak self] searchQuery in
                    guard let self else {
                        return
                    }
                    Task { @MainActor in
                        self.manualCaptureReturnApplication = nil
                        self.requestCaptureViewerSearch(searchQuery)
                    }
                },
                onCancel: { [weak self] in
                    guard let self else {
                        return
                    }
                    Task { @MainActor in
                        self.restoreManualCaptureReturnApplicationIfNeeded()
                    }
                }
            )
        }
    }

    private func resolveManualCaptureApplicationName(from application: NSRunningApplication?) -> String {
        guard
            let applicationName = application?.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            applicationName.isEmpty == false
        else {
            return L10n.string("manual_capture.comment.value.application_unavailable")
        }
        return applicationName
    }

    func performSingleCaptureCycle(
        captureTrigger: CaptureTrigger = .scheduled,
        manualComment: String? = nil
    ) async {
        let scheduler = buildCaptureSchedulerIfNeeded()
        let cycleOutcome = await scheduler.performCaptureCycle(
            captureTrigger: captureTrigger,
            manualComment: manualComment
        )
        await applyCaptureCycleOutcome(cycleOutcome, captureTrigger: captureTrigger)
    }

    private func applyCaptureCycleOutcome(
        _ cycleOutcome: CaptureCycleOutcome,
        captureTrigger: CaptureTrigger
    ) async {
        let cycleOutcomeMessage = makeOutcomeMessage(from: cycleOutcome)
        let cycleOutcomeNotificationMessage = makeNotificationMessage(from: cycleOutcome)
        let cycleOutcomeWindowTitle = resolveCaptureWindowTitle(from: cycleOutcome)
        lastCaptureResultMessage = cycleOutcomeMessage
        await refreshTodayRecordCount()
        if captureTrigger != .scheduled {
            await reportNotificationManager.postCaptureCompletedNotification(
                resultMessage: cycleOutcomeNotificationMessage,
                windowTitle: cycleOutcomeWindowTitle
            )
        }
    }

    private func restoreManualCaptureReturnApplicationIfNeeded() {
        defer {
            manualCaptureReturnApplication = nil
        }
        guard let manualCaptureReturnApplication else {
            return
        }
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        guard manualCaptureReturnApplication.processIdentifier != currentProcessIdentifier else {
            return
        }
        guard manualCaptureReturnApplication.isTerminated == false else {
            return
        }
        _ = manualCaptureReturnApplication.activate(options: [])
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
        hasAccessibilityPermission = FrontmostSelectionTextResolver.isAccessibilityPermissionGranted()
    }

    @discardableResult
    func requestScreenCapturePermission() -> Bool {
        _ = screenCaptureManager.requestScreenCapturePermission()
        refreshPermissionStatus()
        return hasScreenCapturePermission
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        hasRequestedAccessibilityPermissionThisSession = true
        let isGranted = FrontmostSelectionTextResolver.requestAccessibilityPermission()
        refreshPermissionStatus()
        return isGranted
    }

    func openAutomationPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func loadCaptureViewerArtifacts(on targetDate: Date) async {
        isLoadingCaptureViewerArtifacts = true
        captureViewerStatusMessage = ""
        defer {
            isLoadingCaptureViewerArtifacts = false
        }

        do {
            let localDataStore = dataStore
            let artifacts = try await Task.detached(priority: .userInitiated) {
                try localDataStore.loadRecordArtifacts(on: targetDate)
            }.value
            captureViewerArtifacts = artifacts
            if artifacts.isEmpty {
                captureViewerStatusMessage = L10n.string("viewer.message.empty")
            }
        } catch {
            captureViewerArtifacts = []
            captureViewerStatusMessage = L10n.format("viewer.message.load_failed", error.localizedDescription)
        }
    }

    func openCaptureViewerFile(_ fileURL: URL) {
        NSWorkspace.shared.open(fileURL)
    }

    func revealCaptureViewerFile(_ fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func requestCaptureViewerSearch(_ searchQuery: String) {
        captureViewerSearchQuery = searchQuery
        captureViewerSearchRequestSequence &+= 1
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
                timeSlots: AppSettingsResolver.resolveReportTimeSlots(userDefaults: userDefaults)
            )
            await refreshReportSchedulerStatus()
        }
    }

    func generateDailyReport(targetDate: Date = Date()) async {
        await performManualReportGeneration(for: .daily(targetDate: targetDate))
    }

    func generateReportForTimeSlot(_ timeSlot: ReportTimeSlot, targetDate: Date = Date(), isSoleEnabledSlot: Bool = false) async {
        await performManualReportGeneration(
            for: .timeSlot(
                timeSlot: timeSlot,
                targetDate: targetDate,
                isSoleEnabledSlot: isSoleEnabledSlot
            )
        )
    }

    private func performManualReportGeneration(for request: ManualReportRequest) async {
        guard isGeneratingReport == false else {
            return
        }

        isGeneratingReport = true
        lastReportResultMessage = L10n.string("message.report.generating")
        defer {
            isGeneratingReport = false
        }

        do {
            let generatedReport = try await executeManualReportRequest(request)

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
            let errorDescription = error.localizedDescription
            lastReportResultMessage = L10n.format("message.report.failed", errorDescription)
            await reportNotificationManager.postReportFailedNotification(
                errorDescription: errorDescription,
                generationSource: .manual
            )
        }
    }

    private func executeManualReportRequest(_ request: ManualReportRequest) async throws -> GeneratedReport {
        let localReportGenerator = reportGenerator

        switch request {
        case let .daily(targetDate):
            let generationConfiguration = AppSettingsResolver.resolveReportGenerationConfiguration()
            return try await Task.detached(priority: .userInitiated) {
                try await localReportGenerator.generateReport(
                    on: targetDate,
                    configuration: generationConfiguration
                )
            }.value
        case let .timeSlot(timeSlot, targetDate, isSoleEnabledSlot):
            let generationConfiguration = AppSettingsResolver.resolveReportGenerationConfigurationForSlot(
                timeSlot,
                isSoleEnabledSlot: isSoleEnabledSlot
            )
            return try await Task.detached(priority: .userInitiated) {
                try await localReportGenerator.generateReport(
                    for: timeSlot,
                    targetDate: targetDate,
                    configuration: generationConfiguration
                )
            }.value
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
            imageFormat: AppSettingsResolver.resolveCaptureImageFormat(userDefaults: userDefaults),
            excludedApplications: AppSettingsResolver.resolveExcludedApplications(userDefaults: userDefaults),
            excludedWindowTitles: AppSettingsResolver.resolveExcludedWindowTitles(userDefaults: userDefaults)
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
        await notifyIfNeededForScheduledReport(schedulerState)
    }

    private func notifyIfNeededForScheduledReport(_ schedulerState: ReportSchedulerState) async {
        guard schedulerState.lastResultSequence > lastProcessedScheduledResultSequence else {
            return
        }
        lastProcessedScheduledResultSequence = schedulerState.lastResultSequence

        guard let schedulerResult = schedulerState.lastResult else {
            return
        }
        switch schedulerResult {
        case let .succeeded(generatedReport):
            await reportNotificationManager.postReportGeneratedNotification(
                reportFileURL: generatedReport.reportFileURL,
                sourceRecordCount: generatedReport.sourceRecordCount,
                generationSource: .scheduled
            )
        case .skippedNoRecords:
            return
        case let .failed(errorDescription):
            await reportNotificationManager.postReportFailedNotification(
                errorDescription: errorDescription,
                generationSource: .scheduled
            )
        }
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
            if let slotLabel = schedulerState.nextTimeSlotRangeLabel {
                nextMessage += " (\(slotLabel))"
            }
            messageParts.append(nextMessage)
        }
        if let lastResult = schedulerState.lastResult {
            messageParts.append(makeLastSchedulerResultMessage(from: lastResult))
        }

        guard messageParts.isEmpty else {
            return messageParts.joined(separator: " / ")
        }

        let hasEnabledTimeSlot = schedulerState.timeSlots.contains(where: \.isEnabled)
        if hasEnabledTimeSlot {
            return L10n.string("message.scheduler.next_calculating")
        }
        return L10n.string("message.scheduler.no_enabled_slot")
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
                self.startManualCaptureFlow()
            }
        }
        globalHotKeyManager.onRectangleCaptureHotKeyPressed = { [weak self] in
            guard let self else {
                return
            }
            Task { @MainActor in
                self.startRectangleCaptureFlow()
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
                self.updateReportSchedule()
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
        let rectangleCaptureShortcut = AppSettingsResolver.resolveRectangleCaptureShortcutConfiguration(userDefaults: userDefaults)
        globalHotKeyManager.updateRectangleCaptureRegistration(rectangleCaptureShortcut)
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
        case .imageEncodingFailed:
            return L10n.string("capture.skip_reason.image_encoding_failed")
        }
    }
}
