import Foundation

/// Builds a structured Japanese report prompt from local JSON record files.
public struct PromptBuilder: Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Builds one-day report prompt text using relative JSON file references.
    public func buildDailyReportPrompt(
        date: Date,
        relativeJSONGlobPath: String,
        sourceRecordCount: Int,
        customTemplate: String? = nil
    ) -> String {
        let dateLabel = makeDateLabel(from: date)
        let resolvedTemplate = resolveTemplate(customTemplate: customTemplate)

        return replacePlaceholders(
            in: resolvedTemplate,
            dateLabel: dateLabel,
            relativeJSONGlobPath: relativeJSONGlobPath,
            sourceRecordCount: sourceRecordCount
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
        relativeJSONGlobPath: String,
        sourceRecordCount: Int
    ) -> String {
        template
            .replacingOccurrences(of: "{{DATE}}", with: dateLabel)
            .replacingOccurrences(of: "{{JSON_GLOB_PATH}}", with: relativeJSONGlobPath)
            .replacingOccurrences(of: "{{RECORD_COUNT}}", with: String(sourceRecordCount))
    }

    static var defaultTemplate: String {
        NSLocalizedString(
            "report.prompt.default_template",
            value: defaultTemplateFallback,
            comment: ""
        )
    }

    private static let defaultTemplateFallback = """
    以下は{{DATE}}の作業記録データです。
    いまの作業ディレクトリは `timeSlice/data` です。
    次の相対パスに一致する JSON ファイルを読み込んで、内容を要約して日報を作成してください:
    {{JSON_GLOB_PATH}}

    期待レコード件数の目安: {{RECORD_COUNT}} 件

    各 JSON の構造:
    - `applicationName`: フロントアプリ名
    - `capturedAt`: ISO 8601 の記録時刻
    - `ocrText`: OCR結果テキスト
    - `hasImage`: 画像保存フラグ

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
