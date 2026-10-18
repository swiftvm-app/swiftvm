import AppKit
import GuestChannel
import Testing
@testable import SwiftVM

/// Where a guest's windows go on the Mac's screen in Seamless Mode.
@MainActor
@Suite struct SeamlessLayoutTests {
    /// A Retina screen's room for windows below a 33-point menu bar, with the Dock along the bottom.
    private let room = CGRect(x: 0, y: 80, width: 1512, height: 869)

    @Test func theGuestsScreenIsAskedToCoverTheRoomForWindowsPixelForPixel() {
        let size = SeamlessLayout.displaySize(covering: room, backingScale: 2)
        #expect(size.width == 3024 && size.height == 1738)
        // Even, as the machine's window asks for: some drivers round odd sizes down and then don't fit.
        let odd = SeamlessLayout.displaySize(covering: CGRect(x: 0, y: 0, width: 1000.5, height: 700.5), backingScale: 1)
        #expect(odd.width == 1000 && odd.height == 700)
    }

    @Test func aWindowIsWhereItIsInTheGuestCountingDownFromTheTop() throws {
        let layout = SeamlessLayout(screenFrame: room, guestSize: CGSize(width: 3024, height: 1738))
        #expect(layout.pointsPerPixel == 0.5)
        let notepad = GuestWindow(id: 1, x: 200, y: 100, width: 1600, height: 1000)
        let region = try #require(layout.region(of: notepad))
        #expect(region == CGRect(x: 200, y: 100, width: 1600, height: 1000))
        // 50 points from the top of the room, which AppKit counts from the bottom of the screen.
        #expect(layout.frame(of: region) == CGRect(x: 100, y: 80 + 869 - 50 - 500, width: 800, height: 500))

        // A window at the top left of the guest's screen is at the top left of the room, under the menu bar.
        let corner = try #require(layout.region(of: GuestWindow(id: 2, x: 0, y: 0, width: 400, height: 200)))
        #expect(layout.frame(of: corner) == CGRect(x: 0, y: 80 + 869 - 100, width: 200, height: 100))
    }

    @Test func aWindowDroppedOnTheMacIsMovedByAsMuchInTheGuest() {
        let layout = SeamlessLayout(screenFrame: room, guestSize: CGSize(width: 3024, height: 1738))
        let notepad = GuestWindow(id: 1, x: 200, y: 100, width: 1600, height: 1000)
        // 50 points right and 20 up on the Mac: 100 pixels right and 40 up, the guest counting down.
        let moved = layout.guestOrigin(of: notepad, movedBy: CGVector(dx: 50, dy: 20))
        #expect(moved.x == 300 && moved.y == 60)
    }

    @Test func aWindowResizedOnTheMacIsResizedByAsMuchInTheGuest() {
        let layout = SeamlessLayout(screenFrame: room, guestSize: CGSize(width: 3024, height: 1738))
        let notepad = GuestWindow(id: 1, x: 200, y: 100, width: 1600, height: 1000)
        // Its left edge 50 points out and its bottom edge 20 points in: the window starts 100 pixels
        // further left, and is 100 pixels wider and 40 shorter.
        let resized = layout.guestFrame(of: notepad, grownBy: NSEdgeInsets(top: 0, left: 50, bottom: -20, right: 0))
        #expect(resized == (100, 100, 1700, 960))
    }

    @Test func onlyWhatIsOnTheGuestsScreenIsShown() throws {
        let layout = SeamlessLayout(screenFrame: room, guestSize: CGSize(width: 3024, height: 1738))
        // Half dragged off the left edge.
        let region = try #require(layout.region(of: GuestWindow(id: 1, x: -300, y: 100, width: 600, height: 400)))
        #expect(region == CGRect(x: 0, y: 100, width: 300, height: 400))
        #expect(layout.frame(of: region).minX == room.minX)
        // Off the screen altogether, or next to nothing of it on.
        #expect(layout.region(of: GuestWindow(id: 2, x: 4000, y: 100, width: 600, height: 400)) == nil)
        #expect(layout.region(of: GuestWindow(id: 3, x: 3023, y: 100, width: 600, height: 400)) == nil)
    }

    @Test func aGuestScreenOfAnotherSizeKeepsItsWindowsInShape() {
        // The guest didn't take the size it was asked for and stayed at 1920 by 1080, wider than the room.
        let layout = SeamlessLayout(screenFrame: room, guestSize: CGSize(width: 1920, height: 1080))
        let frame = layout.frame(of: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(abs(frame.width / frame.height - 1920.0 / 1080.0) < 0.001)
        #expect(frame.width <= room.width && frame.height <= room.height)
        #expect(frame.maxY == room.maxY)
    }
}
