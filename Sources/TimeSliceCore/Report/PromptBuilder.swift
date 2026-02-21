import Foundation

/// Builds a structured Japanese report prompt from local JSON record files.
public struct PromptBuilder: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Builds report prompt text using one or more relative JSON file references.
    public func buildDailyReportPrompt(
        date: Date,
        relativeJSONGlobPaths: [String],
        sourceRecordCount: Int,
        customTemplate: String? = nil,
        timeRangeLabel: String? = nil
    ) -> String {
        let dateLabel = makeDateLabel(from: date)
        let resolvedTemplate = resolveTemplate(customTemplate: customTemplate)
        let resolvedJSONGlobPaths = relativeJSONGlobPaths.filter { path in
            path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let joinedJSONGlobPath = resolvedJSONGlobPaths.joined(separator: " ")
        let joinedJSONFileList = resolvedJSONGlobPaths.joined(separator: "\n")
        let resolvedTimeRangeLabel = timeRangeLabel ?? NSLocalizedString(
            "report.prompt.all_day", value: "全日", comment: ""
        )

        return replacePlaceholders(
            in: resolvedTemplate,
            dateLabel: dateLabel,
            joinedJSONGlobPath: joinedJSONGlobPath,
            joinedJSONFileList: joinedJSONFileList,
            sourceRecordCount: sourceRecordCount,
            timeRangeLabel: resolvedTimeRangeLabel
        )
    }

    private func resolveTemplate(customTemplate: String?) -> String {
        guard let customTemplate else {
            return Self.defaultTemplate
        }
        let trimmedTemplate = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTemplate.isEmpty == false else {
            return Self.defaultTemplate
        }
        return customTemplate
    }

    private func replacePlaceholders(
        in template: String,
        dateLabel: String,
        joinedJSONGlobPath: String,
        joinedJSONFileList: String,
        sourceRecordCount: Int,
        timeRangeLabel: String
    ) -> String {
        template
            .replacingOccurrences(of: "{{DATE}}", with: dateLabel)
            .replacingOccurrences(of: "{{JSON_GLOB_PATH}}", with: joinedJSONGlobPath)
            .replacingOccurrences(of: "{{RECORD_COUNT}}", with: String(sourceRecordCount))
            .replacingOccurrences(of: "{{TIME_RANGE}}", with: timeRangeLabel)
            .replacingOccurrences(of: "{{JSON_FILE_LIST}}", with: joinedJSONFileList)
    }

    static var defaultTemplate: String {
        NSLocalizedString(
            "report.prompt.default_template",
            value: defaultTemplateFallback,
            comment: ""
        )
    }

    private static let defaultTemplateFallback = """
    以下は{{DATE}} ({{TIME_RANGE}}) の作業記録データです。
    いまの作業ディレクトリは `timeSlice/data` です。
    次のファイルを読み込んで、内容を要約して日報を作成してください:
    {{JSON_FILE_LIST}}

    期待レコード件数の目安: {{RECORD_COUNT}} 件

    各 JSON の構造:
    - `applicationName`: フロントアプリ名
    - `windowTitle`: ウィンドウタイトル（null の場合あり）
    - `capturedAt`: ISO 8601 の記録時刻
    - `ocrText`: OCR結果テキスト
    - `hasImage`: 画像保存フラグ
    - `captureTrigger`: 記録トリガー（`manual` = 今すぐ記録、`scheduled` = 定期キャプチャ）

    重要:
    - 対象時間帯は {{TIME_RANGE}} です。`capturedAt` の時刻がこの範囲に含まれるレコードのみを対象にしてください。
    - `captureTrigger` が `manual` の記録は、ユーザーが意図的に残した重要ログとして優先的に扱ってください。
    - 概要・作業タイムライン・成果物/進捗には、`manual` の記録に基づく内容を必ず含めてください。

    日報を Markdown で作成してください。次の構成を厳守してください:
    1. 概要（2-3文）
    2. 作業タイムライン（時間帯ごと）
    3. 使用アプリケーション一覧と使用時間
    4. 成果物・進捗
    5. 所感（任意）
    """

    private func makeDateLabel(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
