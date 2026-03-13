import AppKit
import Observation
import SwiftUI
import UserNotifications
#if canImport(TimeSliceCore)
import TimeSliceCore
#endif

@main
struct TimeSliceApp: App {
    @NSApplicationDelegateAdaptor(TimeSliceAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuContentView(appState: appState)
        } label: {
            MenuBarStatusLabelView(appState: appState)
        }
        .menuBarExtraStyle(.menu)

        Window(L10n.string("window.settings.title"), id: SettingsWindowIdentifier.main) {
            SettingsView(appState: appState)
        }
        .defaultSize(width: 800, height: 640)
        .windowResizability(.contentSize)

        Window(L10n.string("window.viewer.title"), id: SettingsWindowIdentifier.viewer) {
            CaptureViewerView(appState: appState)
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentSize)
    }
}

final class TimeSliceAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            return
        }
        let notificationUserInfo = response.notification.request.content.userInfo
        if let reportFilePath = notificationUserInfo[ReportNotificationUserInfoKey.reportFilePath] as? String {
            ReportFileOpeningExecutor.executeOpenCommand(reportFilePath: reportFilePath)
            return
        }
        guard notificationUserInfo[CaptureNotificationUserInfoKey.captureRecordID] != nil else {
            return
        }
        NotificationCenter.default.post(
            name: .captureNotificationDidRequestOpenRecord,
            object: nil,
            userInfo: notificationUserInfo
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

private enum SettingsWindowIdentifier {
    static let main = "settings-window"
    static let viewer = "capture-viewer-window"
}

private struct MenuBarStatusLabelView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(
            appState.isCapturing ? L10n.string("app.menu_title.capturing") : L10n.string("app.menu_title.idle"),
            systemImage: appState.isCapturing ? "clock.badge.fill" : "clock"
        )
        .onChange(of: appState.captureViewerSearchRequestSequence) { _, _ in
            guard appState.captureViewerSearchRequestSequence > 0 else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsWindowIdentifier.viewer)
        }
        .onChange(of: appState.captureViewerSelectionRequestSequence) { _, _ in
            guard appState.captureViewerSelectionRequestSequence > 0 else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsWindowIdentifier.viewer)
        }
        .onChange(of: appState.captureViewerOpenRequestSequence) { _, _ in
            guard appState.captureViewerOpenRequestSequence > 0 else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: SettingsWindowIdentifier.viewer)
        }
    }
}

private struct MenuBarMenuContentView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettingsKey.captureNowShortcutKey) private var captureNowShortcutKey = ""
    @AppStorage(AppSettingsKey.captureNowShortcutModifiers) private var captureNowShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.captureNowShortcutKeyCode) private var captureNowShortcutKeyCode = 0
    @AppStorage(AppSettingsKey.rectangleCaptureShortcutKey) private var rectangleCaptureShortcutKey = ""
    @AppStorage(AppSettingsKey.rectangleCaptureShortcutModifiers) private var rectangleCaptureShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.rectangleCaptureShortcutKeyCode) private var rectangleCaptureShortcutKeyCode = 0
    @AppStorage(AppSettingsKey.openViewerShortcutKey) private var openViewerShortcutKey = ""
    @AppStorage(AppSettingsKey.openViewerShortcutModifiers) private var openViewerShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.openViewerShortcutKeyCode) private var openViewerShortcutKeyCode = 0
    @AppStorage(AppSettingsKey.reportTimeSlotsJSON) private var reportTimeSlotsJSON: String = ""

    private var enabledReportSlots: [ReportTimeSlot] {
        AppSettingsResolver.resolveReportTimeSlots().filter(\.isEnabled)
    }

    var body: some View {
        Button {
            openWindowBringingAppToFront(id: SettingsWindowIdentifier.main)
        } label: {
            Label("menu.settings", systemImage: "gearshape")
        }

        Divider()

        if appState.isCapturing {
            Button {
                Task {
                    await appState.stopCapture()
                }
            } label: {
                Label("menu.capture.stop", systemImage: "stop.circle.fill")
            }
        } else {
            Button {
                Task {
                    await appState.startCapture()
                }
            } label: {
                Label("menu.capture.start", systemImage: "play.circle.fill")
            }
        }

        captureNowButton

        captureRectangleButton

        reportGenerateButton

        openViewerButton

        Divider()

        Button {
            showAboutPanel()
        } label: {
            Label("menu.about", systemImage: "info.circle")
        }

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("menu.quit", systemImage: "xmark.circle")
        }
    }

    @ViewBuilder
    private var captureNowButton: some View {
        if
            let captureNowShortcutConfiguration,
            let shortcutCharacter = captureNowShortcutConfiguration.key.first
        {
            Button {
                appState.startManualCaptureFlow()
            } label: {
                Label("menu.capture.now", systemImage: "camera.viewfinder")
            }
            .keyboardShortcut(
                KeyEquivalent(shortcutCharacter),
                modifiers: captureNowShortcutConfiguration.eventModifiers
            )
        } else {
            Button {
                appState.startManualCaptureFlow()
            } label: {
                Label("menu.capture.now", systemImage: "camera.viewfinder")
            }
        }
    }

    @ViewBuilder
    private var captureRectangleButton: some View {
        if
            let rectangleCaptureShortcutConfiguration,
            let shortcutCharacter = rectangleCaptureShortcutConfiguration.key.first
        {
            Button {
                appState.startRectangleCaptureFlow()
            } label: {
                Label(L10n.string("menu.capture.rectangle"), systemImage: "rectangle.dashed.badge.record")
            }
            .keyboardShortcut(
                KeyEquivalent(shortcutCharacter),
                modifiers: rectangleCaptureShortcutConfiguration.eventModifiers
            )
        } else {
            Button {
                appState.startRectangleCaptureFlow()
            } label: {
                Label(L10n.string("menu.capture.rectangle"), systemImage: "rectangle.dashed.badge.record")
            }
        }
    }

    @ViewBuilder
    private var reportGenerateButton: some View {
        let labelText = appState.isGeneratingReport ? L10n.string("menu.report.generating") : L10n.string("menu.report.generate")
        let labelImage = appState.isGeneratingReport ? "hourglass" : "doc.text"
        let slots = enabledReportSlots
        if slots.count >= 2 {
            Menu {
                ForEach(slots) { slot in
                    Button {
                        Task {
                            await appState.generateReportForTimeSlot(slot, isSoleEnabledSlot: false)
                        }
                    } label: {
                        Label(slot.timeRangeLabel, systemImage: "clock")
                    }
                }
            } label: {
                Label(labelText, systemImage: labelImage)
            }
            .disabled(appState.isGeneratingReport)
        } else if let slot = slots.first {
            Button {
                Task {
                    await appState.generateReportForTimeSlot(slot, isSoleEnabledSlot: true)
                }
            } label: {
                Label(labelText, systemImage: labelImage)
            }
            .disabled(appState.isGeneratingReport)
        } else {
            Button {
                Task {
                    await appState.generateDailyReport()
                }
            } label: {
                Label(labelText, systemImage: labelImage)
            }
            .disabled(appState.isGeneratingReport)
        }
    }

    @ViewBuilder
    private var openViewerButton: some View {
        if
            let openViewerShortcutConfiguration,
            let shortcutCharacter = openViewerShortcutConfiguration.key.first
        {
            Button {
                openWindowBringingAppToFront(id: SettingsWindowIdentifier.viewer)
            } label: {
                Label("menu.viewer.open", systemImage: "photo.on.rectangle")
            }
            .keyboardShortcut(
                KeyEquivalent(shortcutCharacter),
                modifiers: openViewerShortcutConfiguration.eventModifiers
            )
        } else {
            Button {
                openWindowBringingAppToFront(id: SettingsWindowIdentifier.viewer)
            } label: {
                Label("menu.viewer.open", systemImage: "photo.on.rectangle")
            }
        }
    }

    private var captureNowShortcutConfiguration: CaptureNowShortcutConfiguration? {
        CaptureNowShortcutResolver.resolveConfiguration(
            shortcutKey: captureNowShortcutKey,
            storedModifiersRawValue: captureNowShortcutModifiersRawValue,
            hasStoredModifiers: UserDefaults.standard.object(forKey: AppSettingsKey.captureNowShortcutModifiers) != nil,
            storedKeyCode: captureNowShortcutKeyCode,
            hasStoredKeyCode: UserDefaults.standard.object(forKey: AppSettingsKey.captureNowShortcutKeyCode) != nil
        )
    }

    private var rectangleCaptureShortcutConfiguration: CaptureNowShortcutConfiguration? {
        CaptureNowShortcutResolver.resolveConfiguration(
            shortcutKey: rectangleCaptureShortcutKey,
            storedModifiersRawValue: rectangleCaptureShortcutModifiersRawValue,
            hasStoredModifiers: UserDefaults.standard.object(forKey: AppSettingsKey.rectangleCaptureShortcutModifiers) != nil,
            storedKeyCode: rectangleCaptureShortcutKeyCode,
            hasStoredKeyCode: UserDefaults.standard.object(forKey: AppSettingsKey.rectangleCaptureShortcutKeyCode) != nil
        )
    }

    private var openViewerShortcutConfiguration: CaptureNowShortcutConfiguration? {
        CaptureNowShortcutResolver.resolveConfiguration(
            shortcutKey: openViewerShortcutKey,
            storedModifiersRawValue: openViewerShortcutModifiersRawValue,
            hasStoredModifiers: UserDefaults.standard.object(forKey: AppSettingsKey.openViewerShortcutModifiers) != nil,
            storedKeyCode: openViewerShortcutKeyCode,
            hasStoredKeyCode: UserDefaults.standard.object(forKey: AppSettingsKey.openViewerShortcutKeyCode) != nil
        )
    }

    private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(
            options: [
                .credits: aboutPanelCredits
            ]
        )
    }

    private func openWindowBringingAppToFront(id windowIdentifier: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: windowIdentifier)
    }

    private var aboutPanelCredits: NSAttributedString {
        let githubURLString = "https://github.com/Nihondo/timeSlice"
        let creditsText = """
        Copyright © 2026 Nihondo
        GitHub: \(githubURLString)
        """
        let attributedCredits = NSMutableAttributedString(string: creditsText)
        let githubURLRange = (creditsText as NSString).range(of: githubURLString)
        if
            githubURLRange.location != NSNotFound,
            let githubURL = URL(string: githubURLString)
        {
            attributedCredits.addAttributes(
                [
                    .link: githubURL,
                    .foregroundColor: NSColor.linkColor
                ],
                range: githubURLRange
            )
        }
        return attributedCredits
    }
}
