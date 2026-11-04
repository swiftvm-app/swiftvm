import CoreGraphics
import CoreML
import Foundation
import Vision

/// Reading what is written on a picture of a screen, on this Mac: for what no accessibility in the guest
/// tells, such as a login screen, or an application that draws itself.
public enum ScreenText {
    public struct Line: Sendable, Equatable {
        public var text: String
        /// In the picture's pixels from its top left corner.
        public var frame: CGRect

        public init(text: String, frame: CGRect) {
            self.text = text
            self.frame = frame
        }
    }

    /// Where `text` is written in `image`, inside `area`: the frame of the only line that says it. `nil`
    /// if none or several do.
    public static func find(_ text: String, in image: CGImage, within area: CGRect) async throws -> CGRect? {
        // Recognition sometimes fails on a picture of a window that is still being drawn. What isn't
        // read is read again with the next picture.
        guard let lines = try? await lines(in: image, within: area) else { return nil }
        return matchingLine(text, among: lines.map(\.text)).map { lines[$0].frame }
    }

    /// The lines written in `image` inside `area`, or all of it.
    public static func lines(in image: CGImage, within area: CGRect? = nil) async throws -> [Line] {
        return try await Task.detached(priority: .userInitiated) {
            let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let area = (area ?? whole).intersection(whole)
            guard !area.isEmpty else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // A program's name is no word of any language.
            request.usesLanguageCorrection = false
            // Vision counts in parts of the picture, upwards from its bottom.
            request.regionOfInterest = CGRect(
                x: area.minX / whole.width, y: 1 - area.maxY / whole.height, width: area.width / whole.width, height: area.height / whole.height
            )
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                // The neural engine's runtime fails at times on a Mac that is short of memory or disk,
                // which a Mac running virtual machines often is. The processor reads the same text.
                guard let processor = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) else {
                    throw error
                }
                request.setComputeDevice(processor, for: .main)
                try VNImageRequestHandler(cgImage: image).perform([request])
            }
            return (request.results ?? []).map { line in
                let box = line.boundingBox
                let frame = CGRect(
                    x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                    width: box.width * area.width, height: box.height * area.height
                )
                return Line(text: line.topCandidates(1).first?.string ?? "", frame: frame)
            }
        }.value
    }

    /// A similar name may be another program, and two matches leave no way to tell which is ours.
    public static func matchingLine(_ text: String, among lines: [String]) -> Int? {
        let wanted = letters(of: text)
        guard !wanted.isEmpty else { return nil }
        var found: Int?
        for (index, line) in lines.enumerated() where letters(of: line) == wanted {
            guard found == nil else { return nil }
            found = index
        }
        return found
    }

    /// The letters and digits of a text, which is what reading a picture gets right: a hyphen comes
    /// out as any of three dashes.
    public static func letters(of text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
