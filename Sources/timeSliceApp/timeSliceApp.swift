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
        .defaultSize(width: 700, height: 640)
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
        guard
            let reportFilePath = response.notification.request.content.userInfo[ReportNotificationUserInfoKey.reportFilePath] as? String
        else {
            return
        }

        ReportFileOpeningExecutor.executeOpenCommand(reportFilePath: reportFilePath)
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

        Button {
            Task {
                await appState.generateDailyReport()
            }
        } label: {
            Label(
                appState.isGeneratingReport ? L10n.string("menu.report.generating") : L10n.string("menu.report.generate"),
                systemImage: appState.isGeneratingReport ? "hourglass" : "doc.text"
            )
        }
        .disabled(appState.isGeneratingReport)

        Button {
            openWindowBringingAppToFront(id: SettingsWindowIdentifier.viewer)
        } label: {
            Label("menu.viewer.open", systemImage: "photo.on.rectangle")
        }

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
