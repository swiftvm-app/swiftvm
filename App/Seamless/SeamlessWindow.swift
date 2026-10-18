import AppKit
import GuestChannel
import VMCore

/// One window of a guest's app on the Mac, in Seamless Mode.
///
/// It has no frame of its own: the guest draws the window's title bar and borders. A window is moved by
/// its title bar the way a Mac window is, by the Mac, and only once it is dropped does the guest move its
/// own there: the picture moves with the pointer, without waiting for the guest. It is resized by its
/// edges as a Mac window is too, from just outside them, where Windows' own borders to resize it by are
/// as well: the guest resizes its window as the edge is dragged, and this one shows it as it does.
final class SeamlessWindow: NSWindow {
    let guestID: GuestWindow.ID
    let regionView: any GuestRegionView
    /// A menu, a tooltip or the like, which only takes the keyboard when the guest gives it the keyboard.
    private(set) var isPopup = false
    /// The guest's window in front, which has the guest's keyboard.
    private(set) var isGuestFocused = false
    /// Asks the guest whether a click at a point of its screen, in its pixels, takes hold of this
    /// window's title bar.
    var isTitleBar: ((CGPoint) async -> Bool)?
    /// Called when the window has been moved by its title bar, by so many points across and up. The guest
    /// is to move its window by as much.
    var onMove: ((CGVector) -> Void)?
    /// Called while the window is resized by its edges, with the guest's window as it was when that
    /// began, and how much larger the window is now on each side, in points outward. The guest is to
    /// make its window as much larger.
    var onResize: ((GuestWindow, NSEdgeInsets) -> Void)?

    private let clip = NSView()
    private let edgesView = EdgesView()
    private var isMaximized = false
    /// The guest's window has borders to resize it by.
    private var hasEdges = false
    /// Room around the window that takes hold of its edges: as much as ``resizeMargin`` for a window
    /// that can be resized, none for one that can't.
    private var margin: CGFloat = 0
    /// The part of the Mac's screen the guest's screen is laid over, which the window stays in.
    private var bounds = CGRect.null
    /// Where the guest's window is on its screen, and where it is shown on the Mac, as the guest last said.
    private var shown: (window: GuestWindow, region: CGRect, frame: CGRect)?
    private var press = Press.none
    /// Counts the presses, so that the answer about one that is over is let go.
    private var presses = 0
    /// A window dropped where the guest hasn't moved its own to yet: until it has, what the guest says is
    /// where it was, and the window stays where it was dropped.
    private var move: (from: GuestWindow, until: ContinuousClock.Instant)?

    /// How round the corners of Windows 11's windows are, in its own pixels at 100%.
    private static let cornerRadius: CGFloat = 8
    /// How far the pointer goes before a press on the title bar moves the window, rather than clicks it.
    private static let dragDistance: CGFloat = 3
    /// How long the guest has to move its window where it was dropped.
    private static let moveTimeout: Duration = .seconds(1)
    /// How far outside its edges a window can be taken hold of to resize it, as a Mac window can.
    static let resizeMargin: CGFloat = 6
    /// How far inside them.
    static let resizeInset: CGFloat = 3
    /// How far along an edge from a corner a press takes hold of the corner.
    static let cornerSize: CGFloat = 16
    /// The smallest a window is made by its edges. The guest may keep its own larger.
    private static let smallest = CGSize(width: 120, height: 60)

    private enum Press {
        case none
        /// Waiting to hear whether the press was on the title bar. What the mouse does meanwhile waits too.
        case asking(down: NSEvent, held: [NSEvent])
        /// Moving the window by its title bar, from where it was when the press began.
        case moving(down: NSEvent, start: CGPoint, origin: CGPoint, hasMoved: Bool)
        /// Resizing the window by some of its edges, from what it was when the press began: where it was
        /// on the Mac without the room around it, the guest's window, and the part of the guest's screen
        /// it showed.
        case resizing(Edges, start: CGPoint, frame: CGRect, window: GuestWindow, region: CGRect)
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }

    init(guestID: GuestWindow.ID, regionView: any GuestRegionView) {
        self.guestID = guestID
        self.regionView = regionView
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        // Clicks too where nothing is drawn: around the window, where it is taken hold of to resize it.
        ignoresMouseEvents = false
        // Each takes its turn with Command-`, and in Mission Control, like any window of the app.
        collectionBehavior = [.managed, .participatesInCycle, .fullScreenNone]
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerCurve = .continuous
        regionView.frame = clip.bounds
        regionView.autoresizingMask = [.width, .height]
        clip.addSubview(regionView)
        clip.autoresizingMask = [.width, .height]
        let content = NSView()
        content.addSubview(clip)
        edgesView.autoresizingMask = [.width, .height]
        content.addSubview(edgesView)
        contentView = content
        initialFirstResponder = regionView
    }

    override var canBecomeKey: Bool { !isPopup || isGuestFocused }
    override var canBecomeMain: Bool { !isPopup }

    /// Shows the guest's window as it is now.
    ///
    /// - Parameters:
    ///   - region: The part of the guest's screen the window is on.
    ///   - frame: Where that is on the Mac's screen.
    ///   - bounds: The part of the Mac's screen the guest's screen is laid over.
    ///   - pixelScale: Points of the Mac's screen to one pixel of the guest's at 100%.
    func show(_ window: GuestWindow, region: CGRect, frame: CGRect, bounds: CGRect, pixelScale: CGFloat) {
        isPopup = window.isPopup
        isGuestFocused = window.isFocused
        isMaximized = window.isMaximized
        hasEdges = window.isResizable && !window.isPopup && !window.isMaximized
        self.bounds = bounds
        if title != window.title {
            title = window.title
        }
        // A window that fills the screen has square corners.
        let radius = window.isMaximized ? 0 : Self.cornerRadius * pixelScale
        if clip.layer?.cornerRadius != radius {
            clip.layer?.cornerRadius = radius
            invalidateShadow()
        }
        shown = (window, region, frame)
        if let move {
            // Still where it was before it was dropped: the window stays where it was dropped.
            if hasSameFrame(window, move.from), ContinuousClock.now < move.until { return }
            self.move = nil
        }
        // Being moved or resized by the Mac: where it is is the Mac's to say until it is let go of.
        if isHeld { return }
        place(region: region, frame: frame)
    }

    /// Closes the window and lets go of what its view draws with.
    func dismiss() {
        regionView.close()
        close()
    }

    /// Shows a part of the guest's screen at a place of the Mac's, with room around it to resize it by.
    private func place(region: CGRect, frame: CGRect) {
        if regionView.region != region {
            regionView.region = region
        }
        let margin = hasEdges ? Self.resizeMargin : 0
        let outer = frame.insetBy(dx: -margin, dy: -margin)
        if self.frame != outer {
            setFrame(outer, display: true)
        }
        if self.margin != margin {
            self.margin = margin
            edgesView.margin = margin
            invalidateCursorRects(for: edgesView)
        }
        let inner = contentView?.bounds.insetBy(dx: margin, dy: margin) ?? .zero
        if clip.frame != inner {
            clip.frame = inner
        }
    }

    /// Where the window is on the Mac, without the room around it.
    private var shownFrame: CGRect { frame.insetBy(dx: margin, dy: margin) }

    private var isHeld: Bool {
        switch press {
        case .moving, .resizing: true
        case .none, .asking: false
        }
    }

    private func hasSameFrame(_ window: GuestWindow, _ other: GuestWindow) -> Bool {
        window.x == other.x && window.y == other.y && window.width == other.width && window.height == other.height
    }

    // MARK: Moving by the title bar

    override func sendEvent(_ event: NSEvent) {
        switch (event.type, press) {
        case (.leftMouseDown, _):
            // A press whose release never came, as when the app was left in the middle of it, is over.
            endPress()
            let edges = edges(at: event.locationInWindow)
            if !edges.isEmpty {
                beginResize(edges)
                return
            }
            guard beginPress(event) else { break }
            return
        case (.leftMouseDragged, .resizing):
            resize()
            return
        case (.leftMouseUp, .resizing):
            endPress()
            return
        case (.leftMouseDragged, .asking(let down, let held)), (.leftMouseUp, .asking(let down, let held)):
            press = .asking(down: down, held: held + [event])
            return
        case (.leftMouseDragged, .moving):
            drag(event)
            return
        case (.leftMouseUp, .moving):
            drop(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Holds a press back while the guest says whether it is on the title bar. Returns `false` for one
    /// that goes to the guest at once: a press on a menu, or on a window that fills the screen, which
    /// Windows moves itself when it is dragged, making it smaller.
    private func beginPress(_ event: NSEvent) -> Bool {
        guard let isTitleBar, let shown, !isPopup, !isMaximized, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return false
        }
        presses += 1
        let number = presses
        press = .asking(down: event, held: [])
        // As a click would.
        if !NSApp.isActive {
            NSApp.activate()
        }
        if canBecomeKey, !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
        let point = guestPoint(of: event.locationInWindow, region: shown.region)
        Task { @MainActor in
            let onTitleBar = await isTitleBar(point)
            guard number == presses, case .asking(let down, let held) = press else { return }
            if onTitleBar {
                press = .moving(down: down, start: NSEvent.mouseLocation, origin: frame.origin, hasMoved: false)
                for event in held {
                    sendEvent(event)
                }
            } else {
                press = .none
                for event in [down] + held {
                    super.sendEvent(event)
                }
            }
        }
        return true
    }

    /// Lets go of a press that is still going on: a window moved or resized by it stays as it was made.
    private func endPress() {
        switch press {
        case .moving(_, _, let origin, true):
            press = .none
            moved(from: origin)
        case .resizing(_, _, let frame, _, _):
            press = .none
            if shownFrame != frame, let shown {
                hold(shown.window)
            }
        default:
            break
        }
        press = .none
    }

    private func drag(_ event: NSEvent) {
        guard case .moving(let down, let start, let origin, var hasMoved) = press else { return }
        let mouse = NSEvent.mouseLocation
        let offset = CGVector(dx: mouse.x - start.x, dy: mouse.y - start.y)
        hasMoved = hasMoved || hypot(offset.dx, offset.dy) >= Self.dragDistance
        press = .moving(down: down, start: start, origin: origin, hasMoved: hasMoved)
        guard hasMoved else { return }
        var moved = CGPoint(x: origin.x + margin + offset.dx, y: origin.y + margin + offset.dy)
        // Kept where the guest's screen is: there is nothing of it to show beyond.
        if !bounds.isNull {
            let size = shownFrame.size
            moved.x = min(max(moved.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
            moved.y = min(max(moved.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        }
        setFrameOrigin(CGPoint(x: moved.x - margin, y: moved.y - margin))
    }

    private func drop(_ event: NSEvent) {
        guard case .moving(let down, _, let origin, let hasMoved) = press else { return }
        press = .none
        guard hasMoved else {
            // A click on the title bar, which is the guest's: twice maximizes the window.
            super.sendEvent(down)
            super.sendEvent(event)
            return
        }
        moved(from: origin)
    }

    /// Has the guest move its window after the one on the Mac, which was moved from `origin`.
    private func moved(from origin: CGPoint) {
        let offset = CGVector(dx: frame.minX - origin.x, dy: frame.minY - origin.y)
        guard offset != .zero, let shown else { return }
        hold(shown.window)
        onMove?(offset)
    }

    /// Keeps the window as the Mac made it while the guest still says its own is as `window`, for as
    /// long as the guest has to catch up.
    private func hold(_ window: GuestWindow) {
        move = (window, ContinuousClock.now + Self.moveTimeout)
        // A guest that doesn't move its window has it back where it was.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.moveTimeout)
            guard let self, let move, ContinuousClock.now >= move.until, let shown = self.shown else { return }
            self.move = nil
            place(region: shown.region, frame: shown.frame)
        }
    }

    // MARK: Resizing by the edges

    /// The edges a press at a point of the window takes hold of: none away from them.
    private func edges(at point: CGPoint) -> Edges {
        guard margin > 0, !isPopup, !isMaximized, let bounds = contentView?.bounds else { return [] }
        let shown = bounds.insetBy(dx: margin, dy: margin)
        guard bounds.contains(point), !shown.insetBy(dx: Self.resizeInset, dy: Self.resizeInset).contains(point) else { return [] }
        let isLeft = point.x < shown.minX + Self.resizeInset, isRight = point.x > shown.maxX - Self.resizeInset
        let isBottom = point.y < shown.minY + Self.resizeInset, isTop = point.y > shown.maxY - Self.resizeInset
        let corner = Self.cornerSize
        var edges: Edges = []
        if isLeft || ((isTop || isBottom) && point.x < shown.minX + corner) { edges.insert(.left) }
        if isRight || ((isTop || isBottom) && point.x > shown.maxX - corner) { edges.insert(.right) }
        if isBottom || ((isLeft || isRight) && point.y < shown.minY + corner) { edges.insert(.bottom) }
        if isTop || ((isLeft || isRight) && point.y > shown.maxY - corner) { edges.insert(.top) }
        return edges
    }

    private func beginResize(_ edges: Edges) {
        guard let shown else { return }
        press = .resizing(edges, start: NSEvent.mouseLocation, frame: shownFrame, window: shown.window, region: shown.region)
        // As a click would.
        if !NSApp.isActive {
            NSApp.activate()
        }
        if canBecomeKey, !isKeyWindow {
            makeKeyAndOrderFront(nil)
        }
    }

    /// Moves the edges taken hold of with the pointer, and shows as much more or less of the guest's
    /// screen: the guest's window as it catches up.
    private func resize() {
        guard case .resizing(let edges, let start, let frame, let window, let region) = press else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.x, dy = mouse.y - start.y
        let room = bounds.isNull ? CGRect.infinite : bounds
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        if edges.contains(.left) { minX = min(max(frame.minX + dx, room.minX), maxX - Self.smallest.width) }
        if edges.contains(.right) { maxX = max(min(frame.maxX + dx, room.maxX), minX + Self.smallest.width) }
        if edges.contains(.bottom) { minY = min(max(frame.minY + dy, room.minY), maxY - Self.smallest.height) }
        if edges.contains(.top) { maxY = max(min(frame.maxY + dy, room.maxY), minY + Self.smallest.height) }
        let resized = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard resized != shownFrame, frame.width > 0 else { return }
        let growth = NSEdgeInsets(top: maxY - frame.maxY, left: frame.minX - minX, bottom: frame.minY - minY, right: maxX - frame.maxX)
        // Pixels of the guest's screen to a point.
        let scale = region.width / frame.width
        regionView.region = CGRect(
            x: region.minX - growth.left * scale, y: region.minY - growth.top * scale,
            width: region.width + (growth.left + growth.right) * scale, height: region.height + (growth.top + growth.bottom) * scale
        )
        setFrame(resized.insetBy(dx: -margin, dy: -margin), display: true)
        onResize?(window, growth)
    }

    /// A point in the window, in the guest's pixels from the top left corner of its screen.
    private func guestPoint(of point: CGPoint, region: CGRect) -> CGPoint {
        let point = clip.convert(point, from: nil)
        let size = clip.bounds.size
        guard size.width > 0, size.height > 0 else { return region.origin }
        return CGPoint(
            x: region.minX + point.x * region.width / size.width,
            y: region.minY + (size.height - point.y) * region.height / size.height
        )
    }
}

/// Shows the pointer for resizing over the edges of a ``SeamlessWindow``, without taking a click: the
/// window takes hold of the edges itself.
private final class EdgesView: NSView {
    /// How far outside the window's edges it can be taken hold of.
    var margin: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        guard margin > 0 else { return }
        let shown = bounds.insetBy(dx: margin, dy: margin)
        let edge = margin + SeamlessWindow.resizeInset, corner = SeamlessWindow.cornerSize
        let across = shown.minX + corner, along = shown.minY + corner
        let wide = shown.width - 2 * corner, tall = shown.height - 2 * corner
        func add(_ rect: CGRect, _ position: NSCursor.FrameResizePosition) {
            addCursorRect(rect, cursor: .frameResize(position: position, directions: .all))
        }
        add(CGRect(x: 0, y: along, width: edge, height: tall), .left)
        add(CGRect(x: bounds.maxX - edge, y: along, width: edge, height: tall), .right)
        add(CGRect(x: across, y: 0, width: wide, height: edge), .bottom)
        add(CGRect(x: across, y: bounds.maxY - edge, width: wide, height: edge), .top)
        let side = margin + corner
        for (rect, position) in [
            (CGRect(x: 0, y: 0, width: side, height: side), NSCursor.FrameResizePosition.bottomLeft),
            (CGRect(x: bounds.maxX - side, y: 0, width: side, height: side), .bottomRight),
            (CGRect(x: 0, y: bounds.maxY - side, width: side, height: side), .topLeft),
            (CGRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side), .topRight),
        ] {
            // Only along the edges: the inside of the corner is the window's.
            add(CGRect(x: rect.minX, y: rect.minY == 0 ? 0 : bounds.maxY - edge, width: rect.width, height: edge), position)
            add(CGRect(x: rect.minX == 0 ? 0 : bounds.maxX - edge, y: rect.minY, width: edge, height: rect.height), position)
        }
    }
}
