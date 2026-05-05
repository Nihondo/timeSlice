// MARK: - UpdateSettingsView.swift
// Sparkleによるアップデート確認状態と設定を表示する。

import SwiftUI

/// アップデート設定を表示する設定タブ。
struct UpdateSettingsView: View {
    let releasesURL: URL

    @ObservedObject private var updateController = AppUpdateController.shared

    var body: some View {
        Form {
            Section {
                currentVersionRow
                lastCheckedRow
            }

            Section {
                checkNowButton
                automaticChecksToggle
            }

            Section {
                releasesLink
            }
        }
        .formStyle(.grouped)
    }

    private var currentVersionRow: some View {
        LabeledContent("settings.update.current_version") {
            Text(versionText)
                .foregroundStyle(.secondary)
        }
    }

    private var lastCheckedRow: some View {
        LabeledContent("settings.update.last_checked") {
            Text(lastCheckedText)
                .foregroundStyle(.secondary)
        }
    }

    private var checkNowButton: some View {
        Button("settings.update.check_now") {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
    }

    private var automaticChecksToggle: some View {
        Toggle(
            "settings.update.automatic_checks",
            isOn: Binding(
                get: { updateController.automaticChecksEnabled },
                set: { updateController.setAutomaticChecksEnabled($0) }
            )
        )
    }

    private var releasesLink: some View {
        Link(destination: releasesURL) {
            HStack {
                Text("settings.update.releases_page")
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    private var lastCheckedText: String {
        guard let lastUpdateCheckDate = updateController.lastUpdateCheckDate else {
            return L10n.string("settings.update.never_checked")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastUpdateCheckDate, relativeTo: Date())
    }
}
