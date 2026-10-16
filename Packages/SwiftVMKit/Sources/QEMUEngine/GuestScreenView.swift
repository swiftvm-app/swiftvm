import AppKit
import QuartzCore

/// Shows what a QEMU machine's display shows, and hands it what the Mac's keyboard and mouse do over it.
///
/// The picture is the surface the VNC client keeps it in, shown by a layer as it is. Several views can
/// show one machine: each shows its ``region`` of the display, all of it unless told otherwise, and
/// passes on places within that region. That is what a window of one Windows app on the Mac would be:
/// a view of the part of the display that app's window is in.
@MainActor
public final class GuestScreenView: NSView {
    private let client: any GuestScreenInput
    private var displaySize: CGSize = .zero
    /// The part of the display shown, in its pixels from the top left corner. `nil` is all of it.
    public var region: CGRect? {
        didSet {
            applyPicture()
            updateCursor()
        }
    }
    /// Send shortcuts such as Command-C to the guest, as the Windows key with C, instead of to the app's
    /// menus. Those macOS itself takes, Command-Tab for one, never come.
    public var capturesSystemKeys = true
    /// Ask the guest to make its display the size of the view whenever the view changes size.
    public var resizesGuest = false {
        didSet { requestFittingSize() }
    }

    private var picture: RFBClient.Picture?
    private var guestCursor: RFBClient.Cursor?
    private var cursor: NSCursor
    private var buttons: RFBClient.Buttons = []
    /// The PC keys that are down, by their scancode, to let go of when the view loses the keyboard.
    private var keysDown: Set<UInt16> = []
    private var modifiersDown: Set<UInt16> = []
    private var scrollRemainder = CGPoint.zero
    /// Where the pointer was put last, in pixels of the display.
    private var lastPlace: (x: Int, y: Int)?
    private var resizeRequest: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?
    /// Takes the release of a key pressed with Command, which AppKit keeps from the view, while the
    /// view has the keyboard.
    private var commandKeyUps: Any?

    /// A pointer that isn't there. Until the guest hands one over, it draws its own into the picture.
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    public convenience init(client: RFBClient) {
        self.init(input: client)
    }

    init(input: any GuestScreenInput, content: NSView? = nil) {
        self.client = input
        cursor = Self.hiddenCursor
        super.init(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layerContentsRedrawPolicy = .never
        if let content {
            content.frame = bounds
            content.autoresizingMask = [.width, .height]
            addSubview(content)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    // MARK: The picture

    /// The display has a new picture, of a new size.
    func show(_ picture: RFBClient.Picture) {
        self.picture = picture
        displaySize = CGSize(width: picture.width, height: picture.height)
        applyPicture()
        updateCursor()
    }

    /// Part of the picture has changed.
    func pictureDidChange() {
        guard let picture, let layer else { return }
        // The surface was written to where it is. A layer only looks again when it is given its
        // contents anew.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        layer.contents = picture.surface
        CATransaction.commit()
    }

    func show(cursor: RFBClient.Cursor?) {
        guestCursor = cursor
        updateCursor()
    }

    private func updateCursor() {
        if let guestCursor, let picture {
            // The guest's cursor and hotspot are in pixels too. On Retina, two guest pixels usually
            // occupy one point of the view, just as they do in the rest of the picture.
            let width = region?.width ?? CGFloat(picture.width)
            let scale = width > 0 ? shownRect.width / width : 1
            let size = NSSize(width: CGFloat(guestCursor.image.width) * scale, height: CGFloat(guestCursor.image.height) * scale)
            let image = NSImage(cgImage: guestCursor.image, size: size)
            let hotSpot = NSPoint(x: guestCursor.hotSpot.x * scale, y: guestCursor.hotSpot.y * scale)
            cursor = NSCursor(image: image, hotSpot: hotSpot)
        } else {
            cursor = Self.hiddenCursor
        }
        window?.invalidateCursorRects(for: self)
    }

    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    private func applyPicture() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = picture?.surface
        if let picture, let region {
            let width = Double(picture.width)
            let height = Double(picture.height)
            layer.contentsRect = CGRect(x: region.minX / width, y: region.minY / height, width: region.width / width, height: region.height / height)
        } else {
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        CATransaction.commit()
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCursor()
        requestFittingSize()
    }

    /// A window moved to another display can change pixel density without changing its size in points.
    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestFittingSize()
    }

    /// The guest draws at the view's backing resolution; Windows' own Scale setting controls text
    /// size. Asking for points instead stretches a low-resolution picture on a Retina display.
    private func requestFittingSize() {
        resizeRequest?.cancel()
        guard resizesGuest, region == nil, window != nil else { return }
        let size = convertToBacking(bounds).size
        let scale = window?.backingScaleFactor ?? 1
        resizeRequest = Task { [client] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Even sizes: some drivers round odd ones down and then don't fit.
            client.requestSize(width: Int(size.width) & ~1, height: Int(size.height) & ~1, scale: scale)
        }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFittingSize()
    }

    // MARK: Places

    func show(size: CGSize) { displaySize = size }

    /// The rectangle in the view that the shown part of the picture takes up, letterboxed as the layer
    /// shows it.
    private var shownRect: CGRect {
        let shown = region ?? CGRect(origin: .zero, size: displaySize)
        guard shown.width > 0, shown.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        let size = CGSize(width: shown.width * scale, height: shown.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// The pixel of the display under a point of the view. The view counts up from its bottom, and the
    /// display down from its top.
    private func pixel(at point: NSPoint) -> (x: Int, y: Int)? {
        guard displaySize.width > 0, displaySize.height > 0 else { return nil }
        let shown = region ?? CGRect(origin: .zero, size: displaySize)
        let rect = shownRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = shown.minX + (point.x - rect.minX) / rect.width * shown.width
        let y = shown.minY + (rect.maxY - point.y) / rect.height * shown.height
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    // MARK: The mouse

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func sendPointer(_ event: NSEvent) {
        guard let place = pixel(at: convert(event.locationInWindow, from: nil)) else { return }
        lastPlace = place
        client.pointer(x: place.x, y: place.y, buttons: buttons)
    }

    override public func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override public func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override public func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override public func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override public func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Control-click is a right click on a Mac.
        buttons.insert(event.modifierFlags.contains(.control) && modifiersDown.isEmpty ? .right : .left)
        sendPointer(event)
    }

    override public func mouseUp(with event: NSEvent) {
        buttons.remove(.left)
        buttons.remove(.right)
        sendPointer(event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        buttons.insert(.right)
        sendPointer(event)
    }

    override public func rightMouseUp(with event: NSEvent) {
        buttons.remove(.right)
        sendPointer(event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        buttons.insert(.middle)
        sendPointer(event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        buttons.remove(.middle)
        sendPointer(event)
    }

    /// How far a trackpad scrolls for one turn of a wheel's notch, in points.
    private static let pointsPerNotch = 24.0

    override public func scrollWheel(with event: NSEvent) {
        guard let place = pixel(at: convert(event.locationInWindow, from: nil)) else { return }
        // The Mac has already turned the direction around if it is set to; what is left is the way
        // the user means to scroll, and a wheel turned up scrolls up in Windows too.
        let perNotch = event.hasPreciseScrollingDeltas ? Self.pointsPerNotch : 1
        scrollRemainder.x += event.scrollingDeltaX / perNotch
        scrollRemainder.y += event.scrollingDeltaY / perNotch
        let notchesY = Int(scrollRemainder.y.rounded(.towardZero))
        let notchesX = Int(scrollRemainder.x.rounded(.towardZero))
        scrollRemainder.y -= Double(notchesY)
        scrollRemainder.x -= Double(notchesX)
        for _ in 0..<min(abs(notchesY), 10) {
            let wheel: RFBClient.Buttons = notchesY > 0 ? .wheelUp : .wheelDown
            client.pointer(x: place.x, y: place.y, buttons: buttons.union(wheel))
            client.pointer(x: place.x, y: place.y, buttons: buttons)
        }
        for _ in 0..<min(abs(notchesX), 10) {
            let wheel: RFBClient.Buttons = notchesX > 0 ? .wheelLeft : .wheelRight
            client.pointer(x: place.x, y: place.y, buttons: buttons.union(wheel))
            client.pointer(x: place.x, y: place.y, buttons: buttons)
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            scrollRemainder = .zero
        }
    }

    // MARK: The keyboard

    override public func keyDown(with event: NSEvent) {
        // The guest repeats a key that is held by itself.
        guard !event.isARepeat, let code = PCKeys.scancode(forMacKey: event.keyCode) else { return }
        keysDown.insert(code)
        client.key(code, down: true)
    }

    override public func keyUp(with event: NSEvent) {
        guard let code = PCKeys.scancode(forMacKey: event.keyCode), keysDown.remove(code) != nil else { return }
        client.key(code, down: false)
    }

    /// The bit of an event's modifier flags that says a modifier key is down, by the Mac's key code:
    /// the flags tell the left one from the right.
    private static let modifierBits: [UInt16: UInt] = [
        0x38: 0x02, 0x3C: 0x04, // Shift
        0x3B: 0x01, 0x3E: 0x2000, // Control
        0x3A: 0x20, 0x3D: 0x40, // Option
        0x37: 0x08, 0x36: 0x10, // Command
    ]

    override public func flagsChanged(with event: NSEvent) {
        guard let code = PCKeys.scancode(forMacKey: event.keyCode) else { return }
        if event.keyCode == 0x39 {
            // Caps Lock says when it changes, not when it is pressed and let go: each change is a press.
            client.key(code, down: true)
            client.key(code, down: false)
            return
        }
        guard let bit = Self.modifierBits[event.keyCode] else { return }
        // Whether the key is down now, not that it changed: one that was held as the view got the
        // keyboard changes only once here, as it is let go, and isn't down in the guest.
        let isDown = event.modifierFlags.rawValue & bit != 0
        if isDown, modifiersDown.insert(code).inserted {
            client.key(code, down: true)
        } else if !isDown, modifiersDown.remove(code) != nil {
            client.key(code, down: false)
        }
    }

    /// Shortcuts that would go to the app's menus go to the guest instead, while it is meant to have them.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturesSystemKeys, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override public func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if commandKeyUps == nil {
            commandKeyUps = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                let isTaken = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.modifierFlags.contains(.command), event.window === self.window,
                          self.window?.firstResponder === self
                    else { return false }
                    self.keyUp(with: event)
                    return true
                }
                return isTaken ? nil : event
            }
        }
        return true
    }

    override public func resignFirstResponder() -> Bool {
        releaseEverything()
        if let commandKeyUps {
            NSEvent.removeMonitor(commandKeyUps)
            self.commandKeyUps = nil
        }
        return super.resignFirstResponder()
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            releaseEverything()
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        if let newWindow {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: newWindow
            )
        }
    }

    @objc private func windowDidResignKey() {
        releaseEverything()
    }

    /// Lets go of every key and button: what is held while the view loses the keyboard would otherwise
    /// stay held in the guest. Command-Tab away from the window does that.
    private func releaseEverything() {
        // The Windows key let go of with nothing pressed in between opens the Start menu. Control in
        // between keeps it closed.
        let windowsKeys = [0x37, 0x36].compactMap { PCKeys.scancode(forMacKey: $0) }
        if !modifiersDown.isDisjoint(with: windowsKeys), let control = PCKeys.scancode(forMacKey: 0x3B), !modifiersDown.contains(control) {
            client.key(control, down: true)
            client.key(control, down: false)
        }
        for code in keysDown.union(modifiersDown) {
            client.key(code, down: false)
        }
        keysDown = []
        modifiersDown = []
        if !buttons.isEmpty, let lastPlace {
            buttons = []
            client.pointer(x: lastPlace.x, y: lastPlace.y, buttons: [])
        }
    }
}
