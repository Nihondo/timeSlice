import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// One image per invocation. Stdout is exclusively UTF-8 OCR text.
@main
struct OCRHelper {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5,
              arguments[1] == "--languages",
              arguments[3] == "--language-correction",
              ["true", "false"].contains(arguments[4]) else {
            fail("Usage: timeSliceOCR <image-path> --languages ja-JP,en-US --language-correction true|false", code: 64)
        }
        let languages = arguments[2].split(separator: ",").map(String.init)
        guard !languages.isEmpty else {
            fail("At least one recognition language is required.", code: 64)
        }
        let imageURL = URL(fileURLWithPath: arguments[0])
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("Could not decode the input image.", code: 65)
        }
        do {
            let recognizer = VisionTextRecognizer(
                recognitionLanguages: languages,
                usesLanguageCorrection: arguments[4] == "true"
            )
            let text = try await recognizer.recognizeText(from: image)
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        } catch {
            fail("Vision OCR failed: \(error)", code: 1)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        exit(code)
    }
}
