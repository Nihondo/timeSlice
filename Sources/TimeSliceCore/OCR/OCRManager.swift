import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Vision based OCR implementation.
public final class OCRManager: TextRecognizing, @unchecked Sendable {
    public let recognitionLanguages: [String]
    public let usesLanguageCorrection: Bool

    public init(
        recognitionLanguages: [String] = ["ja-JP", "en-US"],
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(from image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = usesLanguageCorrection

        // perform waits for completion and throws on failure; no continuation is needed.
        let imageRequestHandler = VNImageRequestHandler(cgImage: image)
        try imageRequestHandler.perform([request])

        let observations = request.results ?? []
        let recognizedLines = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
        let normalizedLines = recognizedLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return normalizedLines.joined(separator: "\n")
    }
}
