import Foundation

/// Detects consecutive duplicate OCR results after normalization.
public actor DuplicateDetector {
    private var lastTextHash: Int?

    public init() {}

    /// Returns `true` when the given text should be stored as a new record.
    public func shouldStoreText(_ text: String) -> Bool {
        let normalizedText = Self.normalizeText(text)
        guard normalizedText.isEmpty == false else {
            return false
        }

        let currentTextHash = normalizedText.hashValue
        guard let lastTextHash else {
            self.lastTextHash = currentTextHash
            return true
        }

        let isSameAsPrevious = currentTextHash == lastTextHash
        if isSameAsPrevious {
            return false
        }

        self.lastTextHash = currentTextHash
        return true
    }

    public func resetCache() {
        lastTextHash = nil
    }

    /// Converts whitespace variants into a canonical form for duplicate checks.
    public static func normalizeText(_ text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else {
            return ""
        }

        let collapsedText = trimmedText
            .replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
        return collapsedText.lowercased()
    }
}
