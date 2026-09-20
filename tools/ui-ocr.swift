import Foundation
import Vision
import AppKit

// OCR over a UI screenshot: the textual "eyes" for autonomous auditing.
// Reads a PNG, runs Vision OCR (zh-Hans + en-US), prints JSON lines with
// recognized text, bounding box (in image pixels), and confidence.

@main struct UIOcr {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 2 else { print("usage: ui-ocr <image.png>"); exit(64) }
        guard let image = NSImage(contentsOfFile: args[1]),
              let tiff = image.tiffRepresentation,
              let cg = NSBitmapImageRep(data: tiff)?.cgImage else {
            print("[]"); exit(1)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { print("[]"); exit(2) }
        var out: [[String: Any]] = []
        for obs in (request.results ?? []) {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let b = obs.boundingBox  // normalized, origin bottom-left
            out.append([
                "text": candidate.string,
                "conf": Double(candidate.confidence),
                "x": Int(b.origin.x * Double(cg.width)),
                "y": Int((1 - b.origin.y - b.height) * Double(cg.height)),  // top-left origin
                "w": Int(b.width * Double(cg.width)),
                "h": Int(b.height * Double(cg.height))
            ])
        }
        // sort top-to-bottom, left-to-right for reading order
        out.sort { ($0["y"] as! Int, $0["x"] as! Int) < ($1["y"] as! Int, $1["x"] as! Int) }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { print(s) }
    }
}