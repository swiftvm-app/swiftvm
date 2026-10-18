import AppKit
import GuestChannel

/// Where a guest's windows go on the Mac in Seamless Mode.
///
/// The guest's screen is laid over the part of the Mac's screen that windows may take, below the menu
/// bar and beside the Dock, one pixel of the guest's to one of the Mac's when the guest took the size
/// it was asked for. A window of the guest goes where it is on that screen.
struct SeamlessLayout: Equatable {
    /// The part of the Mac's screen the guest's screen covers, in points, counting up from the bottom.
    var screenFrame: CGRect
    /// The size of the guest's screen, in its pixels.
    var guestSize: CGSize

    /// Points of the Mac's screen to one pixel of the guest's: the same across and down, so that windows
    /// keep their shape on a guest screen that isn't the size it was asked for.
    var pointsPerPixel: CGFloat {
        guard guestSize.width > 0, guestSize.height > 0 else { return 0 }
        return min(screenFrame.width / guestSize.width, screenFrame.height / guestSize.height)
    }

    /// The part of the guest's screen a window shows: the window, without what is off the screen.
    /// `nil` for a window that has next to nothing on it.
    func region(of window: GuestWindow) -> CGRect? {
        let frame = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
        let shown = frame.intersection(CGRect(origin: .zero, size: guestSize))
        guard !shown.isNull, shown.width >= 2, shown.height >= 2 else { return nil }
        return shown
    }

    /// Where a part of the guest's screen is on the Mac's. The guest counts down from its top.
    func frame(of region: CGRect) -> CGRect {
        let scale = pointsPerPixel
        return CGRect(
            x: screenFrame.minX + region.minX * scale,
            y: screenFrame.maxY - region.maxY * scale,
            width: region.width * scale,
            height: region.height * scale
        )
    }

    /// Where the top left corner of a guest's window goes when its window on the Mac has been moved by
    /// `offset`, in points across and up.
    func guestOrigin(of window: GuestWindow, movedBy offset: CGVector) -> (x: Int, y: Int) {
        let scale = pointsPerPixel
        guard scale > 0 else { return (window.x, window.y) }
        return (window.x + Int((offset.dx / scale).rounded()), window.y - Int((offset.dy / scale).rounded()))
    }

    /// Where a guest's window goes, and how large it is, when its window on the Mac has been made larger
    /// by `growth` on each side, in points outward.
    func guestFrame(of window: GuestWindow, grownBy growth: NSEdgeInsets) -> (x: Int, y: Int, width: Int, height: Int) {
        let scale = pointsPerPixel
        guard scale > 0 else { return (window.x, window.y, window.width, window.height) }
        func pixels(_ points: CGFloat) -> Int { Int((points / scale).rounded()) }
        let left = pixels(growth.left), top = pixels(growth.top)
        return (window.x - left, window.y - top, window.width + left + pixels(growth.right), window.height + top + pixels(growth.bottom))
    }

    /// The size, in pixels, to ask of the guest's screen so that it covers `screenFrame` pixel for pixel.
    /// Even, as the machine's window asks for.
    static func displaySize(covering screenFrame: CGRect, backingScale: CGFloat) -> (width: Int, height: Int) {
        (Int(screenFrame.width * backingScale) & ~1, Int(screenFrame.height * backingScale) & ~1)
    }
}
