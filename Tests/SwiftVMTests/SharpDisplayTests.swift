import CoreGraphics
import Testing
import VMCore
@testable import SwiftVM

/// The size a Windows machine that draws with the Mac's GPU starts at, which its window shows sharply.
@MainActor
@Suite struct SharpDisplayTests {
    @Test func aNewMachineFitsTheScreenItIsMadeOn() {
        // On a wide display the window is as tall as fits, and keeps its shape.
        let wide = SharpDisplay.startingSize(visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1400), backingScale: 2)
        #expect(Double(wide.height) <= 1400 * 2 * SharpDisplay.shareOfScreenHeight)
        #expect(abs(Double(wide.width) / Double(wide.height) - SharpDisplay.aspectRatio) < 0.01)
        // Even sizes, which every driver takes as they are.
        #expect(wide.width % 2 == 0 && wide.height % 2 == 0)
    }

    @Test func itStartsAtTheScaleOfTheScreen() {
        // The guest is told its scale as so many pixels to 72 points.
        let display = SharpDisplay.configuration(startingAt: DisplayPixels(width: 2688, height: 1680, scale: 2))
        #expect(display.pixelsPerInch == 144)
    }
}
