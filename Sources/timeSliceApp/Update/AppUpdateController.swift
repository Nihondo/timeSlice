// MARK: - AppUpdateController.swift
// Sparkle アップデータのシングルトンラッパー。

import Combine
import Sparkle

/// Sparkleのアップデータを管理し、SwiftUIから参照できる状態を公開するコントローラ。
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()

    let updater: SPUUpdater

    private let controller: SPUStandardUpdaterController

    /// 手動アップデートチェックが現在実行可能かどうか。
    @Published var canCheckForUpdates: Bool

    /// Sparkleが最後にアップデートを確認した日時。
    @Published var lastUpdateCheckDate: Date?

    /// 起動時および定期的な自動チェックが有効かどうか。
    @Published var automaticChecksEnabled: Bool

    private var cancellables = Set<AnyCancellable>()

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticChecksEnabled = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    /// 手動アップデートチェックを開始する。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 起動時および定期的な自動チェックの有効状態を切り替える。
    func setAutomaticChecksEnabled(_ isEnabled: Bool) {
        updater.automaticallyChecksForUpdates = isEnabled
        automaticChecksEnabled = isEnabled
    }
}
