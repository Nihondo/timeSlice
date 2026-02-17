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
    @State private var promptTemplateEditorText = ""
    @State private var hasInitializedPromptTemplateEditor = false

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
                    Stepper(L10n.format("settings.stepper.hour", reportAutoGenerationHour), value: $reportAutoGenerationHour, in: 0...23)
                    Stepper(L10n.format("settings.stepper.minute", reportAutoGenerationMinute), value: $reportAutoGenerationMinute, in: 0...59)
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

    private func initializePromptTemplateEditorIfNeeded() {
        guard hasInitializedPromptTemplateEditor == false else {
            return
        }
        promptTemplateEditorText = resolveStoredPromptTemplateText()
        hasInitializedPromptTemplateEditor = true
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
