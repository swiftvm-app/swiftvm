import AppKit
import IOSurface
import Testing
@testable import QEMUEngine

private final class NoInput: GuestScreenInput, @unchecked Sendable {
    func key(_ scancode: UInt16, down: Bool) {}
    func pointer(x: Int, y: Int, buttons: RFBClient.Buttons) {}
    func requestSize(width: Int, height: Int, scale: Double) {}
}

/// A view of part of the display: one window of a Windows app on the Mac, in Seamless Mode.
@MainActor
@Suite struct GuestScreenViewTests {
    /// A display whose top half is red and whose bottom half is blue.
    private func picture() throws -> RFBClient.Picture {
        let surface = try #require(IOSurface(properties: [.width: 4, .height: 4, .bytesPerElement: 4, .pixelFormat: 0x4247_5241]))
        surface.lock(options: [], seed: nil)
        let pixels = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 {
            for column in 0..<4 {
                let pixel = pixels + row * surface.bytesPerRow + column * 4
                // BGRA, from the top row down.
                (pixel[0], pixel[1], pixel[2], pixel[3]) = row < 2 ? (0, 0, 255, 255) : (255, 0, 0, 255)
            }
        }
        surface.unlock(options: [], seed: nil)
        return RFBClient.Picture(surface: surface, width: 4, height: 4)
    }

    /// The colour in the middle of what the view shows: red, blue, or neither.
    private func shownColor(of view: GuestScreenView) throws -> String {
        let layer = try #require(view.layer)
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: 8 / view.bounds.width, y: 8 / view.bounds.height)
        layer.render(in: context)
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self) + 4 * 32 + 4 * 4
        return pixel[0] > 200 && pixel[2] < 60 ? "red" : pixel[2] > 200 && pixel[0] < 60 ? "blue" : "neither"
    }

    @Test func aRegionShowsItsOwnPartOfTheDisplay() throws {
        let view = GuestScreenView(input: NoInput())
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        view.show(try picture())

        // A window at the top of the guest's screen, which counts down from its top.
        view.region = CGRect(x: 0, y: 0, width: 4, height: 2)
        #expect(try shownColor(of: view) == "red")
        view.region = CGRect(x: 0, y: 2, width: 4, height: 2)
        #expect(try shownColor(of: view) == "blue")
    }
}
