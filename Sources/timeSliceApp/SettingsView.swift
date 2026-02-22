import AppKit
import Observation
import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case general
        case capture
        case cli
        case report
        case prompt
    }

    @Bindable var appState: AppState
    @State private var selectedTab: SettingsTab = .general

    @AppStorage(AppSettingsKey.captureIntervalSeconds) private var captureIntervalSeconds = 60.0
    @AppStorage(AppSettingsKey.captureMinimumTextLength) private var minimumTextLength = 10
    @AppStorage(AppSettingsKey.captureShouldSaveImages) private var shouldSaveImages = true
    @AppStorage(AppSettingsKey.reportCLICommand) private var reportCLICommand = "gemini"
    @AppStorage(AppSettingsKey.reportCLIArguments) private var reportCLIArguments = "-p"
    @AppStorage(AppSettingsKey.reportCLITimeoutSeconds) private var reportCLITimeoutSeconds = 300
    @AppStorage(AppSettingsKey.reportAutoGenerationEnabled) private var isReportAutoGenerationEnabled = false
    @AppStorage(AppSettingsKey.reportOutputDirectoryPath) private var reportOutputDirectoryPath = ""
    @AppStorage(AppSettingsKey.reportPromptTemplate) private var reportPromptTemplate = ""
    @AppStorage(AppSettingsKey.captureNowShortcutKey) private var captureNowShortcutKey = ""
    @AppStorage(AppSettingsKey.captureNowShortcutModifiers) private var captureNowShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.captureNowShortcutKeyCode) private var captureNowShortcutKeyCode = 0
    @State private var promptTemplateEditorText = ""
    @State private var hasInitializedPromptTemplateEditor = false
    @State private var excludedApplications: [String] = []
    @State private var excludedApplicationNameInput = ""
    @State private var hasInitializedExcludedApplications = false
    @State private var excludedWindowTitles: [String] = []
    @State private var excludedWindowTitleInput = ""
    @State private var hasInitializedExcludedWindowTitles = false
    @State private var timeSlots: [ReportTimeSlot] = []
    @State private var hasInitializedTimeSlots = false
    @State private var manualReportTargetDate = Date()

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettingsView
                .tabItem {
                    Label("settings.tab.general", systemImage: "gear")
                }
                .tag(SettingsTab.general)

            captureSettingsView
                .tabItem {
                    Label("settings.tab.capture", systemImage: "record.circle")
                }
                .tag(SettingsTab.capture)

            cliSettingsView
                .tabItem {
                    Label("settings.tab.cli", systemImage: "terminal")
                }
                .tag(SettingsTab.cli)

            reportSettingsView
                .tabItem {
                    Label("settings.tab.report", systemImage: "doc.text")
                }
                .tag(SettingsTab.report)

            promptSettingsView
                .tabItem {
                    Label("settings.tab.prompt", systemImage: "text.page")
                }
                .tag(SettingsTab.prompt)
        }
        .frame(
            minWidth: 580,
            idealWidth: 700,
            maxWidth: 1200,
            minHeight: 420,
            idealHeight: 640,
            maxHeight: 1200
        )
        .onAppear {
            initializePromptTemplateEditorIfNeeded()
            initializeExcludedApplicationsIfNeeded()
            initializeExcludedWindowTitlesIfNeeded()
            initializeTimeSlotsIfNeeded()
        }
        .onChange(of: promptTemplateEditorText) { _, newValue in
            updateStoredPromptTemplate(editorText: newValue)
        }
        .onChange(of: isReportAutoGenerationEnabled) { _, _ in
            appState.updateReportSchedule()
        }
    }

    private var generalSettingsView: some View {
        Form {
            Section("settings.section.screen_capture") {
                LabeledContent("settings.label.permission") {
                    Text(appState.hasScreenCapturePermission ? L10n.string("settings.permission.granted") : L10n.string("settings.permission.denied"))
                        .foregroundStyle(appState.hasScreenCapturePermission ? .green : .orange)
                }

                Button("settings.button.refresh_permission") {
                    appState.refreshPermissionStatus()
                }
            }

            Section {
                HStack {
                    Text("settings.label.capture_now_shortcut")
                    Spacer()
                    CaptureNowShortcutRecorderView(
                        shortcutDisplayText: captureNowShortcutDisplayText,
                        hasShortcut: captureNowShortcutConfiguration != nil,
                        onShortcutCaptured: updateCaptureNowShortcut(key:keyCode:modifiers:),
                        onShortcutCleared: clearCaptureNowShortcut
                    )
                }
            } header: {
                Text("settings.section.keyboard_shortcut")
            } footer: {
                Text("settings.footer.keyboard_shortcut")
            }

            Section("settings.section.launch") {
                Toggle("settings.toggle.start_capture_on_launch", isOn: startCaptureOnAppLaunchBinding)
                Toggle("settings.toggle.launch_at_login", isOn: launchAtLoginBinding)

                if appState.launchAtLoginStatusMessage.isEmpty == false {
                    Text(appState.launchAtLoginStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var captureNowShortcutConfiguration: CaptureNowShortcutConfiguration? {
        AppSettingsResolver.resolveCaptureNowShortcutConfiguration()
    }

    private var captureNowShortcutDisplayText: String {
        guard let captureNowShortcutConfiguration else {
            return L10n.string("settings.button.record_shortcut")
        }
        return captureNowShortcutConfiguration.displayText
    }

    private func updateCaptureNowShortcut(key: String, keyCode: Int, modifiers: EventModifiers) {
        captureNowShortcutKey = key
        captureNowShortcutKeyCode = keyCode
        captureNowShortcutModifiersRawValue = Int(modifiers.intersection(CaptureNowShortcutResolver.allowedModifiers).rawValue)
    }

    private func clearCaptureNowShortcut() {
        captureNowShortcutKey = ""
        captureNowShortcutKeyCode = 0
        captureNowShortcutModifiersRawValue = 0
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appState.isLaunchAtLoginEnabled },
            set: { appState.setLaunchAtLoginEnabled($0) }
        )
    }

    private var startCaptureOnAppLaunchBinding: Binding<Bool> {
        Binding(
            get: { appState.isStartCaptureOnAppLaunchEnabled },
            set: { appState.setStartCaptureOnAppLaunchEnabled($0) }
        )
    }

    private var captureSettingsView: some View {
        Form {
            Section("settings.section.interval") {
                LabeledContent("settings.label.capture_interval") {
                    Text(L10n.format("settings.value.seconds", Int(captureIntervalSeconds)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: $captureIntervalSeconds, in: 10...600, step: 10)
            }

            Section {
                Stepper(
                    L10n.format("settings.stepper.minimum_text_length", minimumTextLength),
                    value: $minimumTextLength,
                    in: 1...500
                )
            } header: {
                Text("settings.section.filter")
            } footer: {
                Text("settings.footer.filter")
            }

            Section {
                HStack {
                    LeftAlignedTextField(
                        placeholder: L10n.string("settings.placeholder.excluded_app_name"),
                        text: $excludedApplicationNameInput,
                        onSubmitAction: addExcludedApplication
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("settings.button.add_excluded_app") {
                        addExcludedApplication()
                    }
                    .disabled(canAddExcludedApplication == false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if excludedApplications.isEmpty == false {
                    List {
                        ForEach(excludedApplications, id: \.self) { applicationName in
                            HStack {
                                Text(applicationName)
                                Spacer()
                                Button("settings.button.delete_excluded_app") {
                                    removeExcludedApplication(named: applicationName)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete(perform: deleteExcludedApplications)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                }
            } header: {
                Text("settings.section.excluded_apps")
            } footer: {
                Text("settings.footer.excluded_apps")
            }

            Section {
                HStack {
                    LeftAlignedTextField(
                        placeholder: L10n.string("settings.placeholder.excluded_window_title"),
                        text: $excludedWindowTitleInput,
                        onSubmitAction: addExcludedWindowTitle
                    )
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("settings.button.add_excluded_window_title") {
                        addExcludedWindowTitle()
                    }
                    .disabled(canAddExcludedWindowTitle == false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if excludedWindowTitles.isEmpty == false {
                    List {
                        ForEach(excludedWindowTitles, id: \.self) { excludedWindowTitle in
                            HStack {
                                Text(excludedWindowTitle)
                                Spacer()
                                Button("settings.button.delete_excluded_window_title") {
                                    removeExcludedWindowTitle(containing: excludedWindowTitle)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete(perform: deleteExcludedWindowTitles)
                    }
                    .frame(minHeight: 120, maxHeight: 180)
                }
            } header: {
                Text("settings.section.excluded_window_titles")
            } footer: {
                Text("settings.footer.excluded_window_titles")
            }

            Section {
                Toggle("settings.toggle.save_images", isOn: $shouldSaveImages)
            } header: {
                Text("settings.section.storage")
            } footer: {
                Text("settings.footer.storage")
            }
        }
        .formStyle(.grouped)
    }

    private var cliSettingsView: some View {
        Form {
            Section("settings.section.ai_cli") {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.label.cli_command")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LeftAlignedTextField(
                            placeholder: L10n.string("settings.placeholder.cli_command"),
                            text: $reportCLICommand
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.label.additional_arguments")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LeftAlignedTextField(
                            placeholder: L10n.string("settings.placeholder.additional_arguments"),
                            text: $reportCLIArguments
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Stepper(
                    L10n.format("settings.stepper.timeout_seconds", reportCLITimeoutSeconds),
                    value: $reportCLITimeoutSeconds,
                    in: 30...3600,
                    step: 30
                )
            }
        }
        .formStyle(.grouped)
    }

    private var reportSettingsView: some View {
        Form {
            Section("settings.section.auto_generation") {
                Toggle("settings.toggle.enabled", isOn: $isReportAutoGenerationEnabled)

                if isReportAutoGenerationEnabled {
                    timeSlotsListView
                }

                if appState.lastScheduledReportMessage.isEmpty == false {
                    Text(appState.lastScheduledReportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Section("settings.section.report_output") {
                LabeledContent("settings.label.report_output_directory") {
                    Text(resolveReportOutputDirectoryDisplayText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("settings.button.select_report_output_directory") {
                        selectReportOutputDirectory()
                    }

                    if reportOutputDirectoryPath.isEmpty == false {
                        Button("settings.button.reset_report_output_directory") {
                            reportOutputDirectoryPath = ""
                        }
                    }
                }

                Text("settings.footer.report_output_directory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.section.manual_generation") {
                DatePicker(
                    L10n.string("settings.label.report_target_date"),
                    selection: $manualReportTargetDate,
                    in: ...Date(),
                    displayedComponents: .date
                )

                Button(appState.isGeneratingReport ? L10n.string("settings.button.generating_report") : L10n.string("settings.button.generate_report_now")) {
                    Task {
                        await appState.generateDailyReport(targetDate: manualReportTargetDate)
                    }
                }
                .disabled(appState.isGeneratingReport)

                if appState.lastReportResultMessage.isEmpty == false {
                    Text(appState.lastReportResultMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var promptSettingsView: some View {
        Form {
            Section("settings.section.prompt_template") {
                Text("settings.prompt.placeholders")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptTemplateEditorText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)

                HStack {
                    Button("settings.button.reset_default_prompt") {
                        promptTemplateEditorText = resolveDefaultPromptTemplateText()
                        reportPromptTemplate = ""
                    }

                    Spacer()
                }

                Text("settings.prompt.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var enabledTimeSlotCount: Int {
        timeSlots.filter(\.isEnabled).count
    }

    private var timeSlotsListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($timeSlots) { $slot in
                HStack(spacing: 10) {
                    Toggle("", isOn: $slot.isEnabled)
                        .labelsHidden()
                        .frame(width: 46, alignment: .leading)
                        .onChange(of: slot.isEnabled) { _, _ in
                            saveTimeSlots()
                        }

                    timeSlotTenMinuteControl(
                        hour: $slot.startHour,
                        minute: $slot.startMinute,
                        minimumTotalMinutes: 0,
                        maximumTotalMinutes: 23 * 60 + 50
                    )

                    Text("-")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    timeSlotTenMinuteControl(
                        hour: $slot.endHour,
                        minute: $slot.endMinute,
                        minimumTotalMinutes: 60,
                        maximumTotalMinutes: 30 * 60 + 50
                    )

                    Text(slot.executionIsNextDay ? L10n.string("settings.label.next_day") : "")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(width: 44, alignment: .leading)

                    Button {
                        removeTimeSlot(id: slot.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        Task {
                            let isSole = enabledTimeSlotCount == 1
                            await appState.generateReportForTimeSlot(slot, isSoleEnabledSlot: isSole)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.isGeneratingReport)
                    .help(L10n.string("settings.button.generate_slot_report"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("settings.button.add_time_slot") {
                addTimeSlot()
            }

            Text(L10n.string("settings.footer.time_slots"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func timeSlotTenMinuteControl(
        hour: Binding<Int>,
        minute: Binding<Int>,
        minimumTotalMinutes: Int,
        maximumTotalMinutes: Int
    ) -> some View {
        let totalMinutesBinding = Binding<Int>(
            get: {
                hour.wrappedValue * 60 + minute.wrappedValue
            },
            set: { updatedTotalMinutes in
                let clampedTotalMinutes = min(max(updatedTotalMinutes, minimumTotalMinutes), maximumTotalMinutes)
                let normalizedTotalMinutes = (clampedTotalMinutes / 10) * 10
                let nextHour = normalizedTotalMinutes / 60
                let nextMinute = normalizedTotalMinutes % 60
                guard hour.wrappedValue != nextHour || minute.wrappedValue != nextMinute else {
                    return
                }
                hour.wrappedValue = nextHour
                minute.wrappedValue = nextMinute
                saveTimeSlots()
            }
        )

        return HStack(spacing: 6) {
            Text(String(format: "%02d:%02d", hour.wrappedValue, minute.wrappedValue))
                .font(.system(.body, design: .monospaced))
                .frame(width: 58, alignment: .leading)

            Stepper(
                "",
                value: totalMinutesBinding,
                in: minimumTotalMinutes...maximumTotalMinutes,
                step: 10
            )
                .labelsHidden()
                .fixedSize()
        }
        .frame(width: 108, alignment: .leading)
    }

    private func initializeTimeSlotsIfNeeded() {
        guard hasInitializedTimeSlots == false else {
            return
        }
        hasInitializedTimeSlots = true
        timeSlots = AppSettingsResolver.resolveReportTimeSlots()
    }

    private func addTimeSlot() {
        let newSlot = ReportTimeSlot(
            startHour: 0, startMinute: 0, endHour: 24, endMinute: 0
        )
        timeSlots.append(newSlot)
        saveTimeSlots()
    }

    private func removeTimeSlot(id: UUID) {
        timeSlots.removeAll { $0.id == id }
        saveTimeSlots()
    }

    private func saveTimeSlots() {
        AppSettingsResolver.saveReportTimeSlots(timeSlots)
        appState.updateReportSchedule()
    }

    private func initializePromptTemplateEditorIfNeeded() {
        guard hasInitializedPromptTemplateEditor == false else {
            return
        }
        promptTemplateEditorText = resolveStoredPromptTemplateText()
        hasInitializedPromptTemplateEditor = true
    }

    private var canAddExcludedApplication: Bool {
        let trimmedApplicationName = excludedApplicationNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedApplicationName.isEmpty == false else {
            return false
        }
        return containsExcludedApplication(named: trimmedApplicationName) == false
    }

    private var canAddExcludedWindowTitle: Bool {
        let trimmedWindowTitle = excludedWindowTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWindowTitle.isEmpty == false else {
            return false
        }
        return containsExcludedWindowTitle(containing: trimmedWindowTitle) == false
    }

    private func initializeExcludedApplicationsIfNeeded() {
        guard hasInitializedExcludedApplications == false else {
            return
        }
        excludedApplications = AppSettingsResolver.resolveExcludedApplications()
        hasInitializedExcludedApplications = true
    }

    private func initializeExcludedWindowTitlesIfNeeded() {
        guard hasInitializedExcludedWindowTitles == false else {
            return
        }
        excludedWindowTitles = AppSettingsResolver.resolveExcludedWindowTitles()
        hasInitializedExcludedWindowTitles = true
    }

    private func addExcludedApplication() {
        let trimmedApplicationName = excludedApplicationNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedApplicationName.isEmpty == false else {
            return
        }
        guard containsExcludedApplication(named: trimmedApplicationName) == false else {
            return
        }

        excludedApplications.append(trimmedApplicationName)
        saveExcludedApplications()
        excludedApplicationNameInput = ""
    }

    private func deleteExcludedApplications(at offsets: IndexSet) {
        excludedApplications.remove(atOffsets: offsets)
        saveExcludedApplications()
    }

    private func removeExcludedApplication(named applicationName: String) {
        excludedApplications.removeAll { existingApplicationName in
            existingApplicationName.caseInsensitiveCompare(applicationName) == .orderedSame
        }
        saveExcludedApplications()
    }

    private func containsExcludedApplication(named applicationName: String) -> Bool {
        excludedApplications.contains { existingApplicationName in
            existingApplicationName.caseInsensitiveCompare(applicationName) == .orderedSame
        }
    }

    private func saveExcludedApplications() {
        let normalizedApplications = normalizeExcludedKeywords(excludedApplications)
        excludedApplications = normalizedApplications
        UserDefaults.standard.set(normalizedApplications, forKey: AppSettingsKey.captureExcludedApplications)
    }

    private func addExcludedWindowTitle() {
        let trimmedWindowTitle = excludedWindowTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWindowTitle.isEmpty == false else {
            return
        }
        guard containsExcludedWindowTitle(containing: trimmedWindowTitle) == false else {
            return
        }

        excludedWindowTitles.append(trimmedWindowTitle)
        saveExcludedWindowTitles()
        excludedWindowTitleInput = ""
    }

    private func deleteExcludedWindowTitles(at offsets: IndexSet) {
        excludedWindowTitles.remove(atOffsets: offsets)
        saveExcludedWindowTitles()
    }

    private func removeExcludedWindowTitle(containing windowTitle: String) {
        excludedWindowTitles.removeAll { existingWindowTitle in
            existingWindowTitle.caseInsensitiveCompare(windowTitle) == .orderedSame
        }
        saveExcludedWindowTitles()
    }

    private func containsExcludedWindowTitle(containing windowTitle: String) -> Bool {
        excludedWindowTitles.contains { existingWindowTitle in
            existingWindowTitle.caseInsensitiveCompare(windowTitle) == .orderedSame
        }
    }

    private func saveExcludedWindowTitles() {
        let normalizedWindowTitles = normalizeExcludedKeywords(excludedWindowTitles)
        excludedWindowTitles = normalizedWindowTitles
        UserDefaults.standard.set(normalizedWindowTitles, forKey: AppSettingsKey.captureExcludedWindowTitles)
    }

    private func normalizeExcludedKeywords(_ keywords: [String]) -> [String] {
        var normalizedKeywords = Set<String>()
        var resolvedKeywords: [String] = []

        for keyword in keywords {
            let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedKeyword.isEmpty == false else {
                continue
            }

            let normalizedKeyword = trimmedKeyword.lowercased()
            let isInserted = normalizedKeywords.insert(normalizedKeyword).inserted
            guard isInserted else {
                continue
            }
            resolvedKeywords.append(trimmedKeyword)
        }

        return resolvedKeywords
    }

    private func resolveStoredPromptTemplateText() -> String {
        let trimmedTemplate = reportPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTemplate.isEmpty == false else {
            return resolveDefaultPromptTemplateText()
        }
        return reportPromptTemplate
    }

    private func resolveDefaultPromptTemplateText() -> String {
        PromptBuilder.defaultTemplate
    }

    private func resolveReportOutputDirectoryDisplayText() -> String {
        reportOutputDirectoryPath.isEmpty
            ? L10n.string("settings.value.report_output_default")
            : reportOutputDirectoryPath
    }

    private func selectReportOutputDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = L10n.string("settings.button.select_report_output_directory")
        openPanel.title = L10n.string("settings.panel.select_report_output_directory.title")
        openPanel.message = L10n.string("settings.panel.select_report_output_directory.message")
        if reportOutputDirectoryPath.isEmpty == false {
            openPanel.directoryURL = URL(fileURLWithPath: reportOutputDirectoryPath, isDirectory: true)
        }

        guard openPanel.runModal() == .OK, let selectedDirectoryURL = openPanel.url else {
            return
        }
        reportOutputDirectoryPath = selectedDirectoryURL.path
    }

    private func updateStoredPromptTemplate(editorText: String) {
        let trimmedEditorText = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEditorText.isEmpty || editorText == resolveDefaultPromptTemplateText() {
            reportPromptTemplate = ""
            return
        }
        reportPromptTemplate = editorText
    }
}

private enum CaptureViewerTimeSortOrder: String, CaseIterable, Identifiable {
    case ascending
    case descending

    var id: String {
        rawValue
    }
}

private enum CaptureViewerApplicationFilter: Hashable {
    case all
    case application(String)
}

private enum CaptureViewerCaptureTriggerFilter: String, CaseIterable, Identifiable {
    case all
    case manualOnly

    var id: String {
        rawValue
    }
}

struct CaptureViewerView: View {
    @Bindable var appState: AppState

    @AppStorage(AppSettingsKey.captureViewerTimeSortOrder)
    private var selectedTimeSortOrderRawValue = CaptureViewerTimeSortOrder.ascending.rawValue
    @State private var captureViewerDate = Date()
    @State private var selectedCaptureArtifactID: UUID?
    @State private var selectedApplicationFilter: CaptureViewerApplicationFilter = .all
    @State private var selectedCaptureTriggerFilter: CaptureViewerCaptureTriggerFilter = .all
    @State private var searchInputText = ""
    @State private var confirmedSearchQueryText = ""

    private var normalizedSearchQueryText: String {
        confirmedSearchQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTimeSortOrder: CaptureViewerTimeSortOrder {
        get {
            CaptureViewerTimeSortOrder(rawValue: selectedTimeSortOrderRawValue) ?? .ascending
        }
        nonmutating set {
            selectedTimeSortOrderRawValue = newValue.rawValue
        }
    }

    private var selectedTimeSortOrderBinding: Binding<CaptureViewerTimeSortOrder> {
        Binding(
            get: {
                selectedTimeSortOrder
            },
            set: { updatedSortOrder in
                selectedTimeSortOrder = updatedSortOrder
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DatePicker(
                    L10n.string("viewer.label.target_date"),
                    selection: $captureViewerDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .onChange(of: captureViewerDate) { _, _ in
                    loadCaptureViewerArtifacts()
                }

                Picker("viewer.label.sort_order", selection: selectedTimeSortOrderBinding) {
                    Text("viewer.value.sort_ascending")
                        .tag(CaptureViewerTimeSortOrder.ascending)
                    Text("viewer.value.sort_descending")
                        .tag(CaptureViewerTimeSortOrder.descending)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTimeSortOrderRawValue) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                Picker("viewer.label.application_filter", selection: $selectedApplicationFilter) {
                    Text("viewer.value.filter_all_applications")
                        .tag(CaptureViewerApplicationFilter.all)
                    ForEach(availableApplicationNames, id: \.self) { applicationName in
                        Text(applicationName)
                            .tag(CaptureViewerApplicationFilter.application(applicationName))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedApplicationFilter) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                Picker("viewer.label.capture_trigger_filter", selection: $selectedCaptureTriggerFilter) {
                    Text("viewer.value.filter_all_triggers")
                        .tag(CaptureViewerCaptureTriggerFilter.all)
                    Text("viewer.value.filter_manual_only")
                        .tag(CaptureViewerCaptureTriggerFilter.manualOnly)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedCaptureTriggerFilter) { _, _ in
                    synchronizeSelectedCaptureArtifactIfNeeded()
                }

                TextField("viewer.placeholder.search_text", text: $searchInputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
                    .onSubmit {
                        applyCaptureViewerSearchQuery()
                    }

                Button("viewer.button.reload") {
                    loadCaptureViewerArtifacts()
                }
                .disabled(appState.isLoadingCaptureViewerArtifacts)

                if appState.isLoadingCaptureViewerArtifacts {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(L10n.format("viewer.label.record_count", displayedArtifacts.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.captureViewerStatusMessage.isEmpty == false {
                Text(appState.captureViewerStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HSplitView {
                List(selection: $selectedCaptureArtifactID) {
                    ForEach(displayedArtifacts) { artifact in
                        captureViewerRowView(artifact: artifact)
                            .tag(artifact.id)
                    }
                }
                .listStyle(.inset)
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

                Group {
                    if let selectedCaptureArtifact {
                        captureViewerDetailView(artifact: selectedCaptureArtifact)
                    } else {
                        Text("viewer.placeholder.select_record")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .onAppear {
            guard appState.captureViewerArtifacts.isEmpty else {
                synchronizeApplicationFilterIfNeeded()
                synchronizeSelectedCaptureArtifactIfNeeded()
                return
            }
            loadCaptureViewerArtifacts()
        }
        .onChange(of: appState.captureViewerArtifacts) { _, _ in
            synchronizeApplicationFilterIfNeeded()
            synchronizeSelectedCaptureArtifactIfNeeded()
        }
    }

    private var availableApplicationNames: [String] {
        let uniqueApplicationNames = Set(appState.captureViewerArtifacts.map(\.record.applicationName))
        return uniqueApplicationNames.sorted { leftName, rightName in
            leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private var displayedArtifacts: [CaptureRecordArtifact] {
        let captureTriggerFilteredArtifacts = appState.captureViewerArtifacts.filter { artifact in
            switch selectedCaptureTriggerFilter {
            case .all:
                return true
            case .manualOnly:
                return artifact.record.captureTrigger == .manual
            }
        }
        let applicationFilteredArtifacts = captureTriggerFilteredArtifacts.filter { artifact in
            switch selectedApplicationFilter {
            case .all:
                return true
            case let .application(applicationName):
                return artifact.record.applicationName == applicationName
            }
        }
        let searchFilteredArtifacts = applicationFilteredArtifacts.filter(matchesSearchQuery)
        return searchFilteredArtifacts.sorted(by: compareCaptureArtifactsByTime)
    }

    private var selectedCaptureArtifact: CaptureRecordArtifact? {
        guard let selectedCaptureArtifactID else {
            return nil
        }
        return displayedArtifacts.first { $0.id == selectedCaptureArtifactID }
    }

    private func compareCaptureArtifactsByTime(_ leftArtifact: CaptureRecordArtifact, _ rightArtifact: CaptureRecordArtifact) -> Bool {
        if leftArtifact.record.capturedAt == rightArtifact.record.capturedAt {
            switch selectedTimeSortOrder {
            case .ascending:
                return leftArtifact.record.id.uuidString < rightArtifact.record.id.uuidString
            case .descending:
                return leftArtifact.record.id.uuidString > rightArtifact.record.id.uuidString
            }
        }
        switch selectedTimeSortOrder {
        case .ascending:
            return leftArtifact.record.capturedAt < rightArtifact.record.capturedAt
        case .descending:
            return leftArtifact.record.capturedAt > rightArtifact.record.capturedAt
        }
    }

    private func matchesSearchQuery(_ artifact: CaptureRecordArtifact) -> Bool {
        guard normalizedSearchQueryText.isEmpty == false else {
            return true
        }

        let matchesWindowTitle = artifact.record.windowTitle?.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesOCRText = artifact.record.ocrText.range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        let matchesComment = (artifact.record.comments ?? "").range(
            of: normalizedSearchQueryText,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
        return matchesWindowTitle || matchesOCRText || matchesComment
    }

    private func resolveHighlightedText(_ text: String) -> AttributedString {
        var highlightedText = AttributedString(text)
        guard normalizedSearchQueryText.isEmpty == false else {
            return highlightedText
        }

        var searchRange = text.startIndex..<text.endIndex
        while
            let matchedRange = text.range(
                of: normalizedSearchQueryText,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange
            ),
            let attributedMatchedRange = Range(matchedRange, in: highlightedText)
        {
            highlightedText[attributedMatchedRange].backgroundColor = Color.yellow.opacity(0.35)
            highlightedText[attributedMatchedRange].foregroundColor = .primary
            searchRange = matchedRange.upperBound..<text.endIndex
        }

        return highlightedText
    }

    private func loadCaptureViewerArtifacts() {
        let targetDate = captureViewerDate
        Task { @MainActor in
            await appState.loadCaptureViewerArtifacts(on: targetDate)
            synchronizeApplicationFilterIfNeeded()
            synchronizeSelectedCaptureArtifactIfNeeded()
        }
    }

    private func synchronizeApplicationFilterIfNeeded() {
        switch selectedApplicationFilter {
        case .all:
            return
        case let .application(applicationName):
            let isApplicationPresent = availableApplicationNames.contains(applicationName)
            if isApplicationPresent == false {
                selectedApplicationFilter = .all
            }
        }
    }

    private func synchronizeSelectedCaptureArtifactIfNeeded() {
        guard displayedArtifacts.isEmpty == false else {
            selectedCaptureArtifactID = nil
            return
        }

        let hasSelectedArtifact = displayedArtifacts.contains { artifact in
            artifact.id == selectedCaptureArtifactID
        }
        if hasSelectedArtifact {
            return
        }
        selectedCaptureArtifactID = displayedArtifacts.first?.id
    }

    @ViewBuilder
    private func captureViewerRowView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Self.captureViewerTimeFormatter.string(from: artifact.record.capturedAt))
                    .font(.system(.body, design: .monospaced))

                captureViewerManualIndicatorView(for: artifact.record.captureTrigger)

                Spacer()

                Label(
                    resolveCaptureImageLinkStateText(artifact.imageLinkState),
                    systemImage: resolveCaptureImageLinkStateIconName(artifact.imageLinkState)
                )
                .labelStyle(.iconOnly)
                .foregroundStyle(resolveCaptureImageLinkStateColor(artifact.imageLinkState))
            }

            Text(artifact.record.applicationName)
                .lineLimit(1)

            Text(resolveHighlightedText(windowTitleText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func captureViewerDetailView(artifact: CaptureRecordArtifact) -> some View {
        let windowTitleText = artifact.record.windowTitle?.isEmpty == false
            ? artifact.record.windowTitle ?? ""
            : L10n.string("viewer.value.no_window_title")

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.captureViewerDateTimeFormatter.string(from: artifact.record.capturedAt))
                        .font(.headline)
                    captureViewerManualIndicatorView(for: artifact.record.captureTrigger)
                    Spacer(minLength: 0)
                }

                captureViewerSectionSeparator

                Group {
                    Text("\(L10n.string("viewer.field.application_name")): \(artifact.record.applicationName)")
                    Text("\(L10n.string("viewer.field.window_title")): \(Text(resolveHighlightedText(windowTitleText)))")
                }
                .font(.subheadline)

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.image")
                        .font(.headline)
                    captureViewerImagePreview(artifact: artifact)
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.comments")
                        .font(.headline)
                    captureViewerCommentTextView(comment: artifact.record.comments)
                        .font(.body)
                        .textSelection(.enabled)
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.ocr")
                        .font(.headline)
                    if artifact.record.ocrText.isEmpty {
                        Text("viewer.value.empty_text")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(resolveHighlightedText(artifact.record.ocrText))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                captureViewerSectionSeparator

                VStack(alignment: .leading, spacing: 8) {
                    Text("viewer.section.files")
                        .font(.headline)

                    Text(artifact.jsonFileURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack {
                        Button("viewer.button.open_json") {
                            appState.openCaptureViewerFile(artifact.jsonFileURL)
                        }
                        Button("viewer.button.reveal_json") {
                            appState.revealCaptureViewerFile(artifact.jsonFileURL)
                        }
                    }

                    if let imageFileURL = artifact.imageFileURL {
                        Text(imageFileURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        HStack {
                            Button("viewer.button.open_image") {
                                appState.openCaptureViewerFile(imageFileURL)
                            }
                            .disabled(artifact.imageLinkState != .available)

                            Button("viewer.button.reveal_image") {
                                appState.revealCaptureViewerFile(imageFileURL)
                            }
                            .disabled(artifact.imageLinkState != .available)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var captureViewerSectionSeparator: some View {
        Divider()
            .frame(maxWidth: .infinity)
    }

    private func applyCaptureViewerSearchQuery() {
        confirmedSearchQueryText = searchInputText
        synchronizeSelectedCaptureArtifactIfNeeded()
    }

    @ViewBuilder
    private func captureViewerCommentTextView(comment: String?) -> some View {
        if let comment, comment.isEmpty == false {
            Text(resolveHighlightedText(comment))
        } else {
            Text(resolveCaptureCommentText(comment))
        }
    }

    @ViewBuilder
    private func captureViewerManualIndicatorView(for captureTrigger: CaptureTrigger) -> some View {
        if captureTrigger == .manual {
            Text("viewer.value.trigger_manual")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.16))
                )
        }
    }

    @ViewBuilder
    private func captureViewerImagePreview(artifact: CaptureRecordArtifact) -> some View {
        if artifact.imageLinkState == .notCaptured {
            Text("viewer.message.image_not_captured")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if artifact.imageLinkState == .missingOrExpired {
            Text("viewer.message.image_missing_or_expired")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if
            let imageFileURL = artifact.imageFileURL,
            let image = NSImage(contentsOf: imageFileURL)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("viewer.message.image_load_failed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resolveCaptureImageLinkStateText(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            L10n.string("viewer.value.image_available")
        case .notCaptured:
            L10n.string("viewer.value.image_not_captured")
        case .missingOrExpired:
            L10n.string("viewer.value.image_missing_or_expired")
        }
    }

    private func resolveCaptureImageLinkStateIconName(_ imageLinkState: CaptureImageLinkState) -> String {
        switch imageLinkState {
        case .available:
            "photo"
        case .notCaptured:
            "photo.slash"
        case .missingOrExpired:
            "exclamationmark.triangle"
        }
    }

    private func resolveCaptureImageLinkStateColor(_ imageLinkState: CaptureImageLinkState) -> Color {
        switch imageLinkState {
        case .available:
            .green
        case .notCaptured:
            .secondary
        case .missingOrExpired:
            .orange
        }
    }

    private func resolveCaptureCommentText(_ comment: String?) -> String {
        guard let comment else {
            return L10n.string("viewer.value.no_comment")
        }
        if comment.isEmpty {
            return L10n.string("viewer.value.empty_comment")
        }
        return comment
    }

    private static let captureViewerTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let captureViewerDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct LeftAlignedTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmitAction: (() -> Void)?

    init(
        placeholder: String,
        text: Binding<String>,
        onSubmitAction: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        _text = text
        self.onSubmitAction = onSubmitAction
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.alignment = .left
        textField.placeholderString = placeholder
        textField.stringValue = text
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.handleSubmit)
        textField.delegate = context.coordinator
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.alignment = .left
        if textField.placeholderString != placeholder {
            textField.placeholderString = placeholder
        }
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LeftAlignedTextField

        init(_ parent: LeftAlignedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else {
                return
            }
            parent.text = textField.stringValue
        }

        @objc func handleSubmit() {
            parent.onSubmitAction?()
        }
    }
}

private struct CaptureNowShortcutRecorderView: View {
    let shortcutDisplayText: String
    let hasShortcut: Bool
    let onShortcutCaptured: (String, Int, EventModifiers) -> Void
    let onShortcutCleared: () -> Void

    @State private var isRecordingShortcut = false
    @State private var keyEventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(isRecordingShortcut ? L10n.string("settings.button.shortcut_recording") : shortcutDisplayText) {
                beginShortcutRecording()
            }
            .buttonStyle(BorderedButtonStyle())

            if hasShortcut {
                Button("settings.button.clear_shortcut") {
                    onShortcutCleared()
                }
                .buttonStyle(BorderedButtonStyle())
                .disabled(isRecordingShortcut)
            }
        }
        .onChange(of: isRecordingShortcut) { _, isRecordingShortcut in
            if isRecordingShortcut {
                startKeyEventMonitor()
            } else {
                stopKeyEventMonitor()
            }
        }
        .onDisappear {
            stopKeyEventMonitor()
        }
    }

    private func beginShortcutRecording() {
        isRecordingShortcut = true
    }

    private func startKeyEventMonitor() {
        guard keyEventMonitor == nil else {
            return
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecordingShortcut else {
                return event
            }
            return handleKeyDownEvent(event)
        }
    }

    private func stopKeyEventMonitor() {
        guard let keyEventMonitor else {
            return
        }
        NSEvent.removeMonitor(keyEventMonitor)
        self.keyEventMonitor = nil
    }

    private func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 {
            isRecordingShortcut = false
            return nil
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            onShortcutCleared()
            isRecordingShortcut = false
            return nil
        }

        guard let capturedKey = resolveCapturedKey(event: event) else {
            NSSound.beep()
            return nil
        }

        let capturedModifiers = resolveCapturedModifiers(eventModifierFlags: event.modifierFlags)
        if capturedModifiers.isEmpty {
            NSSound.beep()
            return nil
        }

        onShortcutCaptured(capturedKey, Int(event.keyCode), capturedModifiers)
        isRecordingShortcut = false
        return nil
    }

    private func resolveCapturedModifiers(eventModifierFlags: NSEvent.ModifierFlags) -> EventModifiers {
        var capturedModifiers: EventModifiers = []

        if eventModifierFlags.contains(.command) {
            capturedModifiers.insert(.command)
        }
        if eventModifierFlags.contains(.control) {
            capturedModifiers.insert(.control)
        }
        if eventModifierFlags.contains(.option) {
            capturedModifiers.insert(.option)
        }
        if eventModifierFlags.contains(.shift) {
            capturedModifiers.insert(.shift)
        }

        return capturedModifiers
    }

    private func resolveCapturedKey(event: NSEvent) -> String? {
        guard let inputCharacters = event.charactersIgnoringModifiers, let firstCharacter = inputCharacters.first else {
            return nil
        }
        return CaptureNowShortcutResolver.normalizeStoredKey(String(firstCharacter))
    }
}
