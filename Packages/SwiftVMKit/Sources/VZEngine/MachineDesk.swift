import AppKit
import GuestChannel
import ImageIO
import IOSurface
import UniformTypeIdentifiers
import VMCore
import Virtualization

/// A machine's display, mouse and keyboard, as the Mac that runs it has them.
///
/// The framework has one public way to a guest's display and its input devices: the view that shows a
/// machine to its user. This is such a view of its own, in a window that is never shown. What it would
/// show is read from the surface it shows it with, and what a user would do over it with the mouse and
/// the keyboard is handed to it as the events AppKit would make of that.
///
/// Nothing in the guest is asked, and nothing there has to allow it: it works without the guest tools,
/// at a login screen, and while the guest's screen is locked.
@MainActor
final class MachineDesk {
    private let virtualMachine: VZVirtualMachine
    private let view: VZVirtualMachineView
    private let window: NSWindow
    /// What was asked of the mouse and the keyboard last. The next thing waits for it: two that went
    /// on at once would press each other's keys.
    private var turn = Task<Void, Never> {}
    /// The view has had the time it takes to be handed its first picture.
    private var hasSettled = false

    /// How long the guest gets to take in one event before the next.
    private static let pause: Duration = .milliseconds(12)
    /// The same between what a mouse does, which a guest reads more into: a click is two of them.
    private static let mousePause: Duration = .milliseconds(60)
    /// How far one notch of the wheel scrolls, in the guest's points.
    private static let pointsPerNotch = 40

    init(virtualMachine: VZVirtualMachine) {
        self.virtualMachine = virtualMachine
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        view = VZVirtualMachineView(frame: frame)
        // The display keeps the size its user gave it. This view only looks on.
        view.automaticallyReconfiguresDisplay = false
        view.autoresizingMask = [.width, .height]
        view.virtualMachine = virtualMachine
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView?.addSubview(view)
    }

    func invalidate() {
        view.virtualMachine = nil
        view.removeFromSuperview()
    }

    // MARK: The display

    /// One picture of the display, copied out of the surface that held it.
    struct Frame: Sendable {
        var width: Int
        var height: Int
        var bytesPerRow: Int
        /// Four bytes a pixel: blue, green, red, and one that says nothing.
        var pixels: Data
    }

    func screenshot() async throws -> Data {
        guard let surface = await surface(patience: .seconds(3)) else { throw MachineDeskError.nothingShown }
        let frame = try Self.copy(surface)
        // Packing it takes a moment that the app's windows shouldn't have to wait for.
        return try await Task.detached(priority: .userInitiated) { try Self.png(of: frame) }.value
    }

    /// The surface the view shows the display with, once it has one. A view that was only just made
    /// has none until the framework hands it the guest's picture, and none for as long as the guest
    /// has turned its display off.
    private func surface(patience: Duration) async -> IOSurface? {
        let deadline = ContinuousClock.now + patience
        while true {
            if let surface = view.layer.flatMap(Self.surface(in:)) {
                hasSettled = true
                return surface
            }
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(50))) != nil else {
                hasSettled = true
                return nil
            }
        }
    }

    /// The same for the mouse and the keyboard, which a display that is off is no reason to keep
    /// waiting: they are what wakes it. Only a view that was just made is given its moment.
    private func surfaceForInput() async -> IOSurface? {
        await surface(patience: hasSettled ? .zero : .seconds(2))
    }

    /// The view is the framework's own, and how it shows a display is its business. It does so by
    /// giving one of its layers a surface for its contents, so that is what is looked for.
    private static func surface(in layer: CALayer) -> IOSurface? {
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return unsafeDowncast(contents as AnyObject, to: IOSurface.self)
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = surface(in: sublayer) { return surface }
        }
        return nil
    }

    /// `BGRA`, the one way the framework lays a display's pixels out.
    private static let pixelFormat: OSType = 0x4247_5241

    private static func copy(_ surface: IOSurface) throws -> Frame {
        guard surface.pixelFormat == pixelFormat, surface.width > 0, surface.height > 0 else { throw MachineDeskError.nothingShown }
        // The guest draws into it while it is read. A picture it changed meanwhile is read again.
        var pixels = Data()
        for _ in 1...3 {
            let seed = surface.seed
            surface.lock(options: .readOnly, seed: nil)
            pixels = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
            surface.unlock(options: .readOnly, seed: nil)
            if surface.seed == seed { break }
        }
        return Frame(width: surface.width, height: surface.height, bytesPerRow: surface.bytesPerRow, pixels: pixels)
    }

    nonisolated static func png(of frame: Frame) throws -> Data {
        let layout = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(
                  width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: layout, provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw MachineDeskError.nothingShown }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MachineDeskError.nothingShown }
        return data as Data
    }

    /// How many pixels the display has, which is what places are counted in.
    private func displaySize() async throws -> (width: Int, height: Int) {
        if let surface = await surfaceForInput() {
            return (surface.width, surface.height)
        }
        // A display that is off has no picture, and still has its size.
        guard let size = virtualMachine.graphicsDevices.first?.displays.first?.sizeInPixels, size.width >= 1, size.height >= 1 else {
            throw MachineDeskError.nothingShown
        }
        return (Int(size.width), Int(size.height))
    }

    // MARK: The mouse

    func pointer(_ request: GuestJob.Pointer, guestTurnsWheel: Bool) async throws {
        try await inTurn { [self] in
            let size = try await displaySize()
            let start = try place(request.x, request.y, of: size)
            let button = request.button ?? .left

            switch request.action {
            case .move:
                try await mouse(.moved, button, at: start)
            case .click:
                let count = request.count ?? 1
                guard (1...3).contains(count) else { throw MachineDeskError.invalid("A click is one, two or three clicks.") }
                try await arrive(at: start)
                for _ in 1...count {
                    try await mouse(.down, button, at: start)
                    try await mouse(.up, button, at: start)
                }
            case .drag:
                guard let toX = request.toX, let toY = request.toY else { throw MachineDeskError.invalid("The request doesn't say where the drag ends.") }
                let end = try place(toX, toY, of: size)
                try await arrive(at: start)
                try await mouse(.down, button, at: start)
                // Whatever is dragged follows a pointer that moves, not one that jumps.
                let steps = 12
                for step in 1...steps {
                    let part = Double(step) / Double(steps)
                    try await mouse(.dragged, button, at: NSPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part))
                }
                try await mouse(.up, button, at: end)
            case .scroll:
                let (deltaX, deltaY) = (request.deltaX ?? 0, request.deltaY ?? 0)
                guard abs(deltaX) <= 100, abs(deltaY) <= 100 else { throw MachineDeskError.invalid("That is further than the wheel is turned in one go.") }
                try await arrive(at: start)
                // A wheel counts up for scrolling up, and to the left. A guest that turns it around
                // gets it the other way round, so that what was asked for is what happens.
                let way = guestTurnsWheel ? 1 : -1
                for notch in 0..<max(abs(deltaX), abs(deltaY)) {
                    try await wheel(
                        x: notch < abs(deltaX) ? way * deltaX.signum() * Self.pointsPerNotch : 0,
                        y: notch < abs(deltaY) ? way * deltaY.signum() * Self.pointsPerNotch : 0, at: start
                    )
                }
            }
        }
    }

    /// Where a pixel of the display is in the view's window.
    private func place(_ x: Int, _ y: Int, of size: (width: Int, height: Int)) throws -> NSPoint {
        guard (0..<size.width).contains(x), (0..<size.height).contains(y) else {
            throw MachineDeskError.invalid("(\(x), \(y)) isn't on the screen, which is \(size.width) by \(size.height).")
        }
        // The middle of the pixel, in the view's own points, which count upwards.
        let bounds = view.bounds
        let inView = NSPoint(
            x: (Double(x) + 0.5) / Double(size.width) * bounds.width, y: (1 - (Double(y) + 0.5) / Double(size.height)) * bounds.height
        )
        return view.convert(inView, to: nil)
    }

    /// Brings the pointer to `place` the way a hand does: from a little way off. A pointer that
    /// already rested there when something new came up under it never moved onto that, and a guest
    /// takes its click for one on what was there before.
    private func arrive(at place: NSPoint) async throws {
        let edge = view.convert(view.bounds, to: nil).maxX
        let aside = NSPoint(x: place.x + (place.x + 2 < edge ? 2 : -2), y: place.y)
        try await mouse(.moved, .left, at: aside)
        try await mouse(.moved, .left, at: place)
    }

    private enum MouseEvent {
        case moved, down, up, dragged
    }

    /// Hands the view what a mouse did at `place`, which is in its window.
    private func mouse(_ kind: MouseEvent, _ button: GuestJob.Pointer.Button, at place: NSPoint) async throws {
        let event: NSEvent?
        switch (kind, button) {
        case (.moved, _), (_, .left):
            let type: NSEvent.EventType = switch kind {
            case .moved: .mouseMoved
            case .down: .leftMouseDown
            case .up: .leftMouseUp
            case .dragged: .leftMouseDragged
            }
            event = NSEvent.mouseEvent(
                with: type, location: place, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: kind == .moved ? 0 : 1,
                pressure: kind == .down || kind == .dragged ? 1 : 0
            )
        case (_, .right), (_, .middle):
            // AppKit makes every event it is asked for with the first button. Core Graphics is told which.
            let isRight = button == .right
            let type: CGEventType = switch kind {
            case .down: isRight ? .rightMouseDown : .otherMouseDown
            case .up: isRight ? .rightMouseUp : .otherMouseUp
            case .moved, .dragged: isRight ? .rightMouseDragged : .otherMouseDragged
            }
            event = Self.event(at: place) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: $0, mouseButton: isRight ? .right : .center) }
        }
        guard let event else { throw MachineDeskError.unavailable }
        switch event.type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .rightMouseDragged: view.rightMouseDragged(with: event)
        case .otherMouseDown: view.otherMouseDown(with: event)
        case .otherMouseUp: view.otherMouseUp(with: event)
        case .otherMouseDragged: view.otherMouseDragged(with: event)
        default: throw MachineDeskError.unavailable
        }
        try await Task.sleep(for: Self.mousePause)
    }

    /// Turns the wheel by so many of the guest's points. Only a wheel that counts in points is passed
    /// on: one that counts in lines isn't.
    private func wheel(x: Int, y: Int, at place: NSPoint) async throws {
        let event = Self.event(at: place) { _ in
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0)
        }
        guard let event else { throw MachineDeskError.unavailable }
        view.scrollWheel(with: event)
        try await Task.sleep(for: Self.pause)
    }

    /// An event of the kind only Core Graphics makes, at `place` in the view's window.
    ///
    /// Such an event belongs to no window, so AppKit says where on the screen it happened, and the view
    /// takes that for a place in its window. It is made where the two are the same number.
    private static func event(at place: NSPoint, _ make: (CGPoint) -> CGEvent?) -> NSEvent? {
        // Core Graphics counts down from the top of the first display, AppKit up from its bottom.
        let onScreen = CGPoint(x: place.x, y: CGDisplayBounds(CGMainDisplayID()).height - place.y)
        guard let made = make(onScreen) else { return nil }
        made.location = onScreen
        guard let event = NSEvent(cgEvent: made), abs(event.locationInWindow.x - place.x) < 1, abs(event.locationInWindow.y - place.y) < 1 else {
            return nil
        }
        return event
    }

    // MARK: The keyboard

    func keys(_ request: GuestJob.Keys) async throws {
        // Everything is looked up before anything is typed: half of it is worse than none.
        var presses: [MacKeys.Press] = []
        for character in request.text ?? "" {
            guard let press = MacKeys.press(typing: character) else { throw MachineDeskError.notOnTheKeyboard(character) }
            presses.append(press)
        }
        do {
            presses += try (request.keys ?? []).map(MacKeys.press(for:))
        } catch let problem as MacKeys.NoSuchKey {
            throw MachineDeskError.invalid(problem.message)
        }
        guard !presses.isEmpty else { throw MachineDeskError.invalid("The request has neither text to type nor keys to press.") }
        try await inTurn { [self] in
            // A view that was only just made isn't listened to yet.
            _ = await surfaceForInput()
            for press in presses {
                try await self.press(press)
            }
        }
    }

    /// What every key event says of the keys that are held, when none is.
    private static let noModifiers = NSEvent.ModifierFlags(rawValue: 0x100)

    /// What a held key adds to that: its kind, and that it is the one on the left of the keyboard. The
    /// view goes by the second, as it has to for a guest that tells the two apart.
    private static func flags(of modifier: MacKeys.Modifier) -> NSEvent.ModifierFlags {
        switch modifier {
        case .command: [.command, NSEvent.ModifierFlags(rawValue: 0x8)]
        case .shift: [.shift, NSEvent.ModifierFlags(rawValue: 0x2)]
        case .option: [.option, NSEvent.ModifierFlags(rawValue: 0x20)]
        case .control: [.control, NSEvent.ModifierFlags(rawValue: 0x1)]
        }
    }

    private func press(_ press: MacKeys.Press) async throws {
        // The keys to hold go down one after the other, each knowing of those before it, and come up
        // the other way round.
        var held = Self.noModifiers
        for modifier in press.modifiers {
            held.formUnion(Self.flags(of: modifier))
            try await key(.flagsChanged, modifier.key, held)
        }
        if let key = press.key {
            try await self.key(.keyDown, key, held)
            try await self.key(.keyUp, key, held)
        }
        for modifier in press.modifiers.reversed() {
            held.subtract(Self.flags(of: modifier))
            try await key(.flagsChanged, modifier.key, held)
        }
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ held: NSEvent.ModifierFlags) async throws {
        // The view goes by the key's number. Which character that makes is the guest's business.
        let event = NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: held, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        )
        guard let event else { throw MachineDeskError.unavailable }
        switch type {
        case .keyDown: view.keyDown(with: event)
        case .keyUp: view.keyUp(with: event)
        default: view.flagsChanged(with: event)
        }
        try await Task.sleep(for: Self.pause)
    }

    // MARK: One thing after the other

    private func inTurn(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let before = turn
        let mine = Task { @MainActor in
            await before.value
            try await work()
        }
        turn = Task { _ = try? await mine.value }
        try await mine.value
    }
}
