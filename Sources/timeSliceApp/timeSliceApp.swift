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
        MenuBarExtra(
            appState.isCapturing ? L10n.string("app.menu_title.capturing") : L10n.string("app.menu_title.idle"),
            systemImage: appState.isCapturing ? "clock.badge.fill" : "clock"
        ) {
            MenuBarMenuContentView(appState: appState)
        }
        .menuBarExtraStyle(.menu)

        Window(L10n.string("window.settings.title"), id: SettingsWindowIdentifier.main) {
            SettingsView(appState: appState)
        }
        .defaultSize(width: 700, height: 640)
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
}

private struct MenuBarMenuContentView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppSettingsKey.captureNowShortcutKey) private var captureNowShortcutKey = ""
    @AppStorage(AppSettingsKey.captureNowShortcutModifiers) private var captureNowShortcutModifiersRawValue = 0
    @AppStorage(AppSettingsKey.captureNowShortcutKeyCode) private var captureNowShortcutKeyCode = 0

    var body: some View {
        Button {
            openWindow(id: SettingsWindowIdentifier.main)
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
                Task {
                    await appState.performSingleCaptureCycle(captureTrigger: .manual)
                }
            } label: {
                Label("menu.capture.now", systemImage: "camera.viewfinder")
            }
            .keyboardShortcut(
                KeyEquivalent(shortcutCharacter),
                modifiers: captureNowShortcutConfiguration.eventModifiers
            )
        } else {
            Button {
                Task {
                    await appState.performSingleCaptureCycle(captureTrigger: .manual)
                }
            } label: {
                Label("menu.capture.now", systemImage: "camera.viewfinder")
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
}
