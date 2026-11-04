import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One picture of a machine's display, as the Mac that runs it reads it: nothing in the guest is asked.
public struct ScreenFrame: Sendable {
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    /// Four bytes a pixel: blue, green, red, and one that says nothing.
    public var pixels: Data

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    /// The frame that a PNG shows, for an engine that only hands out pictures.
    public init?(png: Data) {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let (width, height) = (image.width, image.height)
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let isDrawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.layout.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard isDrawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
    }

    private static let layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    public var image: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.layout, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// The whole frame, without losing a pixel.
    public func png() -> Data? {
        image.flatMap { Self.encoded($0, as: .png, options: [:]) }
    }

    /// A part of the frame, in its pixels, made `divisor` times smaller. What a model looks at: a
    /// fraction of the size of a PNG, and as readable.
    public func jpeg(region: CGRect? = nil, divisor: Double = 1, quality: Double = 0.7) -> Data? {
        guard var image else { return nil }
        if let region {
            guard let part = image.cropping(to: region.integral) else { return nil }
            image = part
        }
        if divisor > 1 {
            let (width, height) = (max(Int((Double(image.width) / divisor).rounded()), 1), max(Int((Double(image.height) / divisor).rounded()), 1))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: Self.layout.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let smaller = context.makeImage() else { return nil }
            image = smaller
        }
        return Self.encoded(image, as: .jpeg, options: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encoded(_ image: CGImage, as type: UTType, options: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Every fourth pixel of every fourth row, to compare with another frame's: quick enough to ask many
    /// times a second.
    public var sample: [UInt32] {
        pixels.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var sample: [UInt32] = []
            sample.reserveCapacity(width / 4 * height / 4 + 1)
            var row = 0
            while row < height {
                let start = row * bytesPerRow
                guard start + width * 4 <= buffer.count else { break }
                let line = buffer.baseAddress! + start
                var column = 0
                while column < width {
                    sample.append(line.load(fromByteOffset: column * 4, as: UInt32.self))
                    column += 4
                }
                row += 4
            }
            return sample
        }
    }

    /// How many of two samples' pixels differ. A blinking caret or a clock changes a handful; anything a
    /// person would call the screen changing, more.
    public static func difference(between first: [UInt32], and second: [UInt32]) -> Int {
        guard first.count == second.count else { return .max }
        var count = 0
        for index in first.indices where first[index] != second[index] {
            count += 1
        }
        return count
    }
}
