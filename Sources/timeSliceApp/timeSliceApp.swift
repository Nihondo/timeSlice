import AppKit
import Observation
import SwiftUI
#if canImport(TimeSliceCore)
import TimeSliceCore
#endif

@main
struct TimeSliceApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra(
            appState.isCapturing ? L10n.string("app.menu_title.capturing") : L10n.string("app.menu_title.idle"),
            systemImage: appState.isCapturing ? "record.circle.fill" : "record.circle"
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

private enum SettingsWindowIdentifier {
    static let main = "settings-window"
}

private struct MenuBarMenuContentView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: SettingsWindowIdentifier.main)
        } label: {
            Label("menu.settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

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

        Button {
            Task {
                await appState.performSingleCaptureCycle(captureTrigger: .manual)
            }
        } label: {
            Label("menu.capture.now", systemImage: "camera.viewfinder")
        }

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
        .keyboardShortcut("q", modifiers: .command)
    }
}
