import AppKit
import VMCore

/// The size a guest's display starts at, for a guest that takes a new size only as it starts: Windows
/// drawing with the Mac's GPU. Its window shows that size pixel for pixel, and so sharply.
enum SharpDisplay {
    /// How much of the room for windows a new machine's window takes, across.
    static let shareOfScreenWidth = 0.75
    /// Its shape: 16 by 10, as a Mac's own screen.
    static let aspectRatio = 1.6
    /// The most of the room for windows it takes, down, leaving some for the window's title bar.
    static let shareOfScreenHeight = 0.8

    /// The size for a new machine on `screen`: a window that fits comfortably in the room for windows,
    /// in the screen's pixels.
    static func startingSize(for screen: NSScreen? = NSScreen.main) -> DisplayPixels {
        guard let screen else { return DisplayPixels(width: 2560, height: 1600, scale: 2) }
        return startingSize(visibleFrame: screen.visibleFrame, backingScale: screen.backingScaleFactor)
    }

    static func startingSize(visibleFrame: CGRect, backingScale: CGFloat) -> DisplayPixels {
        var width = visibleFrame.width * shareOfScreenWidth
        var height = width / aspectRatio
        if height > visibleFrame.height * shareOfScreenHeight {
            height = visibleFrame.height * shareOfScreenHeight
            width = height * aspectRatio
        }
        // Even sizes, as the machine's window asks for: some drivers round odd ones down and then don't fit.
        return DisplayPixels(
            width: Int((width * backingScale).rounded()) & ~1,
            height: Int((height * backingScale).rounded()) & ~1,
            scale: backingScale
        )
    }

    /// The configuration of a display that starts at `size`.
    static func configuration(startingAt size: DisplayPixels) -> DisplayConfiguration {
        DisplayConfiguration(
            widthInPixels: size.width, heightInPixels: size.height,
            pixelsPerInch: Int((size.scale * 72).rounded()), adapter: .framebuffer
        )
    }
}
