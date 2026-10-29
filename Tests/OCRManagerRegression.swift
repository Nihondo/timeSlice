// Standalone regression harness; it is not part of the app target.
// Compile with TextRecognizing.swift and OCRManager.swift (see CLAUDE.md).
import CoreGraphics
import CoreText
import Darwin
import Foundation
import ObjectiveC
@preconcurrency import Vision

@main
struct OCRManagerRegression {
    static func makeImage(text: String) -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 160, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 36, nil),
                         NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        context.textPosition = CGPoint(x: 30, y: 65)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    static func checkFailureRecovery(manager: OCRManager, image: CGImage) async {
        let method = class_getInstanceMethod(VNImageRequestHandler.self, NSSelectorFromString("performRequests:error:"))!
        let failure = NSError(domain: "OCRManagerRegression", code: 13)
        typealias PerformBlock = @convention(block) (AnyObject, NSArray, UnsafeMutablePointer<NSError?>?) -> Bool
        let block: PerformBlock = { _, requests, error in
            for case let request as VNRequest in requests {
                // Model Vision notifying the completion AND failing perform for the same request.
                request.completionHandler?(request, failure)
            }
            error?.pointee = failure
            return false
        }
        let replacement = imp_implementationWithBlock(block)
        let original = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        for _ in 0..<3 {
            do {
                _ = try await manager.recognizeText(from: image)
                fatalError("Expected injected Vision failure")
            } catch {
                let actual = error as NSError
                precondition(actual.domain == failure.domain && actual.code == 13)
            }
        }

        // A completed request with no observations is a valid empty OCR result.
        let succeed: PerformBlock = { _, _, _ in true }
        let successImplementation = imp_implementationWithBlock(succeed)
        method_setImplementation(method, successImplementation)
        defer {
            method_setImplementation(method, replacement)
            imp_removeBlock(successImplementation)
        }
        do {
            let recovered = try await manager.recognizeText(from: image)
            precondition(recovered.isEmpty)
        } catch {
            fatalError("OCR failed to recover after injected errors: \(error)")
        }
    }

    static func main() async {
        setbuf(stdout, nil)
        let manager = OCRManager()
        let text = "timeSlice OCR recovery 123"
        let image = makeImage(text: text)
        await checkFailureRecovery(manager: manager, image: image)
        print("PASS: three Vision errors propagated without terminating the process")
        print("PASS: a subsequent successful request returns empty observations")
        guard CommandLine.arguments.contains("--real-vision") else { return }
        do {
            let recognized = try await manager.recognizeText(from: image)
            precondition(recognized == text, "Unexpected OCR output: \(recognized)")
            print("PASS: real Vision text recognition succeeds after errors")
            let blank = try await manager.recognizeText(from: makeImage(text: ""))
            precondition(blank.isEmpty)
            print("PASS: blank image returns empty text")
        } catch {
            print("FAIL: real Vision error was caught without terminating: \(error)")
            exit(EXIT_FAILURE)
        }
    }
}
