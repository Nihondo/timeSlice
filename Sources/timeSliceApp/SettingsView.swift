import AppKit
import Observation
import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case general
        case capture
        case cli
        case report
    }

    @Bindable var appState: AppState
    @State private var selectedTab: SettingsTab = .general

    @AppStorage(AppSettingsKey.captureIntervalSeconds) private var captureIntervalSeconds = 60.0
    @AppStorage(AppSettingsKey.captureMinimumTextLength) private var minimumTextLength = 10
    @AppStorage(AppSettingsKey.captureShouldSaveImages) private var shouldSaveImages = true
    @AppStorage(AppSettingsKey.reportCLICommand) private var reportCLICommand = "gemini"
    @AppStorage(AppSettingsKey.reportCLIArguments) private var reportCLIArguments = "-p"
    @AppStorage(AppSettingsKey.reportCLITimeoutSeconds) private var reportCLITimeoutSeconds = 300
    @AppStorage(AppSettingsKey.reportTargetDayOffset) private var reportTargetDayOffset = 0
    @AppStorage(AppSettingsKey.reportAutoGenerationEnabled) private var isReportAutoGenerationEnabled = false
    @AppStorage(AppSettingsKey.reportAutoGenerationHour) private var reportAutoGenerationHour = 18
    @AppStorage(AppSettingsKey.reportAutoGenerationMinute) private var reportAutoGenerationMinute = 0
    @AppStorage(AppSettingsKey.reportOutputDirectoryPath) private var reportOutputDirectoryPath = ""
    @AppStorage(AppSettingsKey.reportPromptTemplate) private var reportPromptTemplate = ""
    @AppStorage(AppSettingsKey.reportTimeSlotsEnabled) private var isTimeSlotsEnabled = false
    @AppStorage(AppSettingsKey.captureNowShortcutKey) private var captureNowShortcutKey = ""
    @AppStorage(AppSettingsKey.captureNowShortcutModifiers) private var captureNowShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.captureNowShortcutKeyCode) private var captureNowShortcutKeyCode = 0
    @State private var promptTemplateEditorText = ""
    @State private var hasInitializedPromptTemplateEditor = false
    @State private var excludedApplications: [String] = []
    @State private var excludedApplicationNameInput = ""
    @State private var hasInitializedExcludedApplications = false
    @State private var timeSlots: [ReportTimeSlot] = []
    @State private var hasInitializedTimeSlots = false

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
            initializeTimeSlotsIfNeeded()
        }
        .onChange(of: promptTemplateEditorText) { _, newValue in
            updateStoredPromptTemplate(editorText: newValue)
        }
        .onChange(of: isReportAutoGenerationEnabled) { _, _ in
            appState.updateReportSchedule()
        }
        .onChange(of: reportAutoGenerationHour) { _, _ in
            appState.updateReportSchedule()
        }
        .onChange(of: reportAutoGenerationMinute) { _, _ in
            appState.updateReportSchedule()
        }
        .onChange(of: isTimeSlotsEnabled) { _, _ in
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
                    TextField("settings.placeholder.excluded_app_name", text: $excludedApplicationNameInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addExcludedApplication()
                        }

                    Button("settings.button.add_excluded_app") {
                        addExcludedApplication()
                    }
                    .disabled(canAddExcludedApplication == false)
                }

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.label.cli_command")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("settings.placeholder.cli_command", text: $reportCLICommand)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.label.additional_arguments")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("settings.placeholder.additional_arguments", text: $reportCLIArguments)
                        .textFieldStyle(.roundedBorder)
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
            Section("settings.section.report_target") {
                Stepper(
                    L10n.format("settings.stepper.report_target_day_offset", reportTargetDayOffset),
                    value: $reportTargetDayOffset,
                    in: -7...0
                )
            }

            Section("settings.section.auto_generation") {
                Toggle("settings.toggle.enabled", isOn: $isReportAutoGenerationEnabled)

                if isReportAutoGenerationEnabled {
                    Toggle("settings.toggle.use_time_slots", isOn: $isTimeSlotsEnabled)

                    if isTimeSlotsEnabled {
                        timeSlotsListView
                    } else {
                        Stepper(L10n.format("settings.stepper.hour", reportAutoGenerationHour), value: $reportAutoGenerationHour, in: 0...23)
                        Stepper(L10n.format("settings.stepper.minute", reportAutoGenerationMinute), value: $reportAutoGenerationMinute, in: 0...59)
                    }
                }

                if appState.lastScheduledReportMessage.isEmpty == false {
                    Text(appState.lastScheduledReportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Section("settings.section.prompt_template") {
                Text("settings.prompt.placeholders")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $promptTemplateEditorText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)

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
                Button(appState.isGeneratingReport ? L10n.string("settings.button.generating_report") : L10n.string("settings.button.generate_report_now")) {
                    Task {
                        await appState.generateDailyReport()
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

    private var timeSlotsListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($timeSlots) { $slot in
                HStack(spacing: 8) {
                    Toggle("", isOn: $slot.isEnabled)
                        .labelsHidden()
                        .onChange(of: slot.isEnabled) { _, _ in
                            saveTimeSlots()
                        }

                    TextField("settings.placeholder.time_slot_label", text: $slot.label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: slot.label) { _, _ in
                            saveTimeSlots()
                        }

                    Stepper(
                        String(format: "%02d:%02d", slot.startHour, slot.startMinute),
                        value: $slot.startHour,
                        in: 0...23
                    )
                    .onChange(of: slot.startHour) { _, _ in
                        saveTimeSlots()
                    }

                    Text("-")

                    Stepper(
                        String(format: "%02d:%02d", slot.endHour, slot.endMinute),
                        value: $slot.endHour,
                        in: 0...24
                    )
                    .onChange(of: slot.endHour) { _, _ in
                        saveTimeSlots()
                    }

                    Button {
                        removeTimeSlot(id: slot.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)

                    Button {
                        Task {
                            await appState.generateReportForTimeSlot(slot)
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(appState.isGeneratingReport)
                    .help(L10n.string("settings.button.generate_slot_report"))
                }
            }

            Button("settings.button.add_time_slot") {
                addTimeSlot()
            }
        }
    }

    private func initializeTimeSlotsIfNeeded() {
        guard hasInitializedTimeSlots == false else {
            return
        }
        hasInitializedTimeSlots = true

        if let jsonData = UserDefaults.standard.data(forKey: AppSettingsKey.reportTimeSlotsJSON),
           let decoded = try? JSONDecoder().decode([ReportTimeSlot].self, from: jsonData),
           decoded.isEmpty == false {
            timeSlots = decoded
        } else {
            timeSlots = ReportTimeSlot.defaults
            AppSettingsResolver.saveReportTimeSlots(timeSlots)
        }
    }

    private func addTimeSlot() {
        let newSlot = ReportTimeSlot(
            label: L10n.string("time_slot.new"),
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

    private func initializeExcludedApplicationsIfNeeded() {
        guard hasInitializedExcludedApplications == false else {
            return
        }
        excludedApplications = AppSettingsResolver.resolveExcludedApplications()
        hasInitializedExcludedApplications = true
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
        let normalizedApplications = normalizeExcludedApplications(excludedApplications)
        excludedApplications = normalizedApplications
        UserDefaults.standard.set(normalizedApplications, forKey: AppSettingsKey.captureExcludedApplications)
    }

    private func normalizeExcludedApplications(_ applicationNames: [String]) -> [String] {
        var normalizedApplicationNames = Set<String>()
        var normalizedApplications: [String] = []

        for applicationName in applicationNames {
            let trimmedApplicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedApplicationName.isEmpty == false else {
                continue
            }

            let normalizedApplicationName = trimmedApplicationName.lowercased()
            let isInserted = normalizedApplicationNames.insert(normalizedApplicationName).inserted
            guard isInserted else {
                continue
            }
            normalizedApplications.append(trimmedApplicationName)
        }

        return normalizedApplications
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
