import Testing
@testable import QEMUEngine

/// What Windows' agent puts behind the guest's windows in Seamless Mode shows as nothing on the Mac.
@Suite struct SeamlessBackdropTests {
    @Test func theBackdropIsSeeThroughAndEverythingElseOpaque() {
        // BGRA as QEMU sends it, with a fourth byte that says nothing: the backdrop, black, and white.
        var pixels: [UInt8] = [1, 0, 1, 0, 0, 0, 0, 0, 255, 255, 255, 0]
        pixels.withUnsafeMutableBytes { RFBClient.clearBackdrop($0) }
        #expect(pixels == [0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 255])
    }
}
