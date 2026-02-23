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
            Section("settings.section.permissions") {
                HStack {
                    Text("settings.label.permission.screen_recording")
                    Spacer()
                    Text(appState.hasScreenCapturePermission ? L10n.string("settings.permission.granted") : L10n.string("settings.permission.denied"))
                        .foregroundStyle(appState.hasScreenCapturePermission ? .green : .orange)
                    Button("settings.button.request_permission") {
                        _ = appState.requestScreenCapturePermission()
                    }
                }

                HStack {
                    Text("settings.label.permission.text_selection")
                    Spacer()
                    Text(appState.hasAccessibilityPermission ? L10n.string("settings.permission.granted") : L10n.string("settings.permission.denied"))
                        .foregroundStyle(appState.hasAccessibilityPermission ? .green : .orange)
                    Button("settings.button.request_permission") {
                        _ = appState.requestAccessibilityPermission()
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.label.permission.automation")
                        Spacer()
                        Button("settings.button.open_system_settings") {
                            appState.openAutomationPrivacySettings()
                        }
                    }
                    Text("settings.description.automation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        canAddExcludedKeyword(excludedApplicationNameInput, in: excludedApplications)
    }

    private var canAddExcludedWindowTitle: Bool {
        canAddExcludedKeyword(excludedWindowTitleInput, in: excludedWindowTitles)
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
        guard let updatedKeywords = buildAddedExcludedKeywords(
            from: excludedApplicationNameInput,
            currentKeywords: excludedApplications
        ) else {
            return
        }
        excludedApplications = persistExcludedKeywords(
            updatedKeywords,
            storageKey: AppSettingsKey.captureExcludedApplications
        )
        excludedApplicationNameInput = ""
    }

    private func deleteExcludedApplications(at offsets: IndexSet) {
        excludedApplications = deleteExcludedKeywords(
            at: offsets,
            from: excludedApplications,
            storageKey: AppSettingsKey.captureExcludedApplications
        )
    }

    private func removeExcludedApplication(named applicationName: String) {
        excludedApplications = removeExcludedKeyword(
            applicationName,
            from: excludedApplications,
            storageKey: AppSettingsKey.captureExcludedApplications
        )
    }

    private func containsExcludedApplication(named applicationName: String) -> Bool {
        containsExcludedKeyword(applicationName, in: excludedApplications)
    }

    private func addExcludedWindowTitle() {
        guard let updatedKeywords = buildAddedExcludedKeywords(
            from: excludedWindowTitleInput,
            currentKeywords: excludedWindowTitles
        ) else {
            return
        }
        excludedWindowTitles = persistExcludedKeywords(
            updatedKeywords,
            storageKey: AppSettingsKey.captureExcludedWindowTitles
        )
        excludedWindowTitleInput = ""
    }

    private func deleteExcludedWindowTitles(at offsets: IndexSet) {
        excludedWindowTitles = deleteExcludedKeywords(
            at: offsets,
            from: excludedWindowTitles,
            storageKey: AppSettingsKey.captureExcludedWindowTitles
        )
    }

    private func removeExcludedWindowTitle(containing windowTitle: String) {
        excludedWindowTitles = removeExcludedKeyword(
            windowTitle,
            from: excludedWindowTitles,
            storageKey: AppSettingsKey.captureExcludedWindowTitles
        )
    }

    private func containsExcludedWindowTitle(containing windowTitle: String) -> Bool {
        containsExcludedKeyword(windowTitle, in: excludedWindowTitles)
    }

    private func canAddExcludedKeyword(_ rawKeyword: String, in keywords: [String]) -> Bool {
        guard let resolvedKeyword = resolveNonEmptyKeyword(from: rawKeyword) else {
            return false
        }
        return containsExcludedKeyword(resolvedKeyword, in: keywords) == false
    }

    private func buildAddedExcludedKeywords(from rawKeyword: String, currentKeywords: [String]) -> [String]? {
        guard let resolvedKeyword = resolveNonEmptyKeyword(from: rawKeyword) else {
            return nil
        }
        guard containsExcludedKeyword(resolvedKeyword, in: currentKeywords) == false else {
            return nil
        }
        return currentKeywords + [resolvedKeyword]
    }

    private func deleteExcludedKeywords(
        at offsets: IndexSet,
        from keywords: [String],
        storageKey: String
    ) -> [String] {
        var updatedKeywords = keywords
        updatedKeywords.remove(atOffsets: offsets)
        return persistExcludedKeywords(updatedKeywords, storageKey: storageKey)
    }

    private func removeExcludedKeyword(
        _ keyword: String,
        from keywords: [String],
        storageKey: String
    ) -> [String] {
        let updatedKeywords = keywords.filter { existingKeyword in
            existingKeyword.caseInsensitiveCompare(keyword) != .orderedSame
        }
        return persistExcludedKeywords(updatedKeywords, storageKey: storageKey)
    }

    private func persistExcludedKeywords(_ keywords: [String], storageKey: String) -> [String] {
        let normalizedKeywords = ExcludedKeywordNormalizer.normalizeKeywords(keywords)
        UserDefaults.standard.set(normalizedKeywords, forKey: storageKey)
        return normalizedKeywords
    }

    private func containsExcludedKeyword(_ keyword: String, in keywords: [String]) -> Bool {
        keywords.contains { existingKeyword in
            existingKeyword.caseInsensitiveCompare(keyword) == .orderedSame
        }
    }

    private func resolveNonEmptyKeyword(from rawKeyword: String) -> String? {
        let trimmedKeyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKeyword.isEmpty == false else {
            return nil
        }
        return trimmedKeyword
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
