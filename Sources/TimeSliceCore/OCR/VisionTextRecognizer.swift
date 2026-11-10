import CoreGraphics
import Foundation
@preconcurrency import Vision

/// In-process Vision implementation, used only by the one-shot OCR helper.
final class VisionTextRecognizer: TextRecognizing, @unchecked Sendable {
    let recognitionLanguages: [String]
    let usesLanguageCorrection: Bool

    init(
        recognitionLanguages: [String] = ["ja-JP", "en-US"],
        usesLanguageCorrection: Bool = true
    ) {
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    func recognizeText(from image: CGImage) async throws -> String {
        try autoreleasepool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = usesLanguageCorrection

            // perform waits for completion and throws; keep a single error path.
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }
}
