// Isolated fake executable for OCRProcessRegression; never included in app products.
import Darwin
import Foundation
import ImageIO

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 5, args[1] == "--languages", args[3] == "--language-correction" else { exit(64) }
let imageURL = URL(fileURLWithPath: args[0])
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == 640 else { exit(65) }
let metadata: [String: Any] = ["pid": getpid(), "imagePath": imageURL.path, "correction": args[4], "text": "日本語\nOCR test"]
let data = try JSONSerialization.data(withJSONObject: metadata)
let marker = imageURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("started-\(getpid()).json")
try data.write(to: marker)
switch args[2] {
case "success":
    try FileHandle.standardError.write(contentsOf: Data("diagnostic only".utf8))
    try FileHandle.standardOutput.write(contentsOf: data)
case "empty": break
case "failure":
    try FileHandle.standardOutput.write(contentsOf: Data("partial result must be discarded".utf8))
    try FileHandle.standardError.write(contentsOf: Data("injected failure".utf8))
    exit(17)
case "signal": kill(getpid(), SIGKILL)
case "hang":
    signal(SIGTERM, SIG_IGN)
    while true { pause() }
case "large":
    try FileHandle.standardOutput.write(contentsOf: Data(repeating: 97, count: 192 * 1024))
    try FileHandle.standardError.write(contentsOf: Data(repeating: 98, count: 256 * 1024))
case "overflow":
    try FileHandle.standardOutput.write(contentsOf: Data(repeating: 97, count: 5 * 1024 * 1024))
case "invalid":
    try FileHandle.standardOutput.write(contentsOf: Data([0xff, 0xfe]))
default: exit(64)
}
