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
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let recognizedLines = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                let normalizedLines = recognizedLines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                continuation.resume(returning: normalizedLines.joined(separator: "\n"))
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = recognitionLanguages
            request.usesLanguageCorrection = usesLanguageCorrection

            do {
                let imageRequestHandler = VNImageRequestHandler(cgImage: image)
                try imageRequestHandler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
