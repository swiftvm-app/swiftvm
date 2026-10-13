import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VZEngine

@Suite struct MachineDeskTests {
    @Test func aPictureOfTheDisplayKeepsItsColors() throws {
        // Two pixels as a display's surface has them: blue first, then green, red, and a byte that
        // says nothing. A red one and a blue one, in a row that is longer than its pixels.
        let frame = MachineDesk.Frame(width: 2, height: 1, bytesPerRow: 12, pixels: Data([0, 0, 255, 0, 255, 0, 0, 0, 9, 9, 9, 9]))
        let png = try MachineDesk.png(of: frame)

        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2 && image.height == 1)
        var pixels = [UInt8](repeating: 0, count: 8)
        let context = try #require(CGContext(
            data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(Array(pixels[0..<3]) == [255, 0, 0])
        #expect(Array(pixels[4..<7]) == [0, 0, 255])
    }
}
