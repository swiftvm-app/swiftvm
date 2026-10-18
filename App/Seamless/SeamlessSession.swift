import AppKit
import GuestChannel
import Observation
import VMCore

/// Seamless Mode for one machine: each window on the guest's screen in a window of its own on the Mac,
/// and nothing else of the guest. The guest's agent says which windows there are and where; the Mac's
/// windows follow it.
///
/// The guest's screen is made the size of the Mac's, so that a window is as large on the Mac as it is
/// in the guest, and the guest's windows may take all of it: its taskbar isn't shown.
final class SeamlessSession: NSObject {
    let machine: VirtualMachine
    /// Called once the session is over by itself: the machine stopped, or can't show its windows.
    var onEnd: ((_ problem: String?) -> Void)?
    /// Called when one of the session's windows has become the one in front.
    var onUse: (() -> Void)?

    private var windows: [GuestWindow.ID: SeamlessWindow] = [:]
    /// The guest's windows that have a window on the Mac, front to back, as they were stacked last.
    private var stacked: [GuestWindow.ID] = []
    /// The guest's window that had the keyboard when the Mac's windows were last brought in line.
    private var focused: GuestWindow.ID?
    /// The session is giving one of its windows the keyboard itself, which the guest needn't be told.
    private var isFocusing = false
    private var isRunning = false
    /// The guest has said where its windows are, and the Mac's are brought in line with the display's
    /// next picture.
    private var isUpdateWaiting = false
    /// When the Start menu was last asked for. The app comes forward with it, and the window that then
    /// becomes the Mac's key window is already the guest's: bringing it forward would close Start.
    private var startMenuShown: ContinuousClock.Instant?

    /// How long after the Start menu is asked for that the guest isn't told of a window becoming key.
    private static let startMenuGrace: Duration = .milliseconds(500)

    init(machine: VirtualMachine) {
        self.machine = machine
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensDidChange), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
        watchState()
        fitGuestToScreen()
        machine.agent.reportWindows(true)
        update()
    }

    /// Ends the session: the guest's windows go, and its taskbar comes back.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        machine.agent.reportWindows(false)
        NotificationCenter.default.removeObserver(self)
        windows.values.forEach { $0.dismiss() }
        windows = [:]
        stacked = []
        focused = nil
    }

    /// Opens the guest's Start menu, which comes up as a window of its own above the Dock.
    func showStartMenu() {
        startMenuShown = .now
        Task {
            try? await machine.pressKeys(GuestJob.Keys(keys: ["win"]))
        }
    }

    // MARK: Following the guest

    /// Brings the Mac's windows in line with the guest's, as its agent last reported them, once the
    /// display shows them there. Its agent says so on a line of its own, which can be a picture ahead.
    func scheduleUpdate() {
        guard isRunning, !isUpdateWaiting else { return }
        isUpdateWaiting = true
        machine.afterDisplayUpdate { [weak self] in
            guard let self else { return }
            isUpdateWaiting = false
            update()
        }
    }

    /// Brings the Mac's windows in line with the guest's, as its agent last reported them.
    func update() {
        guard isRunning else { return }
        guard let list = machine.agent.windows, let screen = NSScreen.screens.first, list.width > 0, list.height > 0 else {
            // The agent is on its way back, after a restart of the guest: its windows are gone for now.
            close(Set(windows.keys))
            stacked = []
            return
        }
        let layout = SeamlessLayout(screenFrame: screen.visibleFrame, guestSize: CGSize(width: list.width, height: list.height))
        let pixelScale = layout.pointsPerPixel * screen.backingScaleFactor
        var shown: [GuestWindow.ID] = []
        var opened: Set<GuestWindow.ID> = []
        for guest in list.windows {
            guard let region = layout.region(of: guest) else { continue }
            let window: SeamlessWindow
            if let existing = windows[guest.id] {
                window = existing
            } else {
                guard let regionView = machine.makeRegionView() else {
                    onEnd?("This copy of SwiftVM's display can't show the guest's windows one by one.")
                    return
                }
                window = makeWindow(for: guest.id, regionView: regionView)
                windows[guest.id] = window
                opened.insert(guest.id)
            }
            window.show(guest, region: region, frame: layout.frame(of: region), bounds: screen.visibleFrame, pixelScale: pixelScale)
            shown.append(guest.id)
        }
        stack(shown, opened: opened)
        focus(list.windows.first { $0.isFocused && windows[$0.id] != nil }?.id)
        // Gone only now that the guest's window in front has the keyboard. The Mac would otherwise hand
        // it to a window of its choosing, and the guest would be told to bring that one forward.
        close(Set(windows.keys).subtracting(shown))
    }

    private func makeWindow(for id: GuestWindow.ID, regionView: any GuestRegionView) -> SeamlessWindow {
        let window = SeamlessWindow(guestID: id, regionView: regionView)
        window.isTitleBar = { [agent = machine.agent] point in
            await agent.isTitleBar(of: id, x: Int(point.x), y: Int(point.y))
        }
        window.onMove = { [weak self] offset in self?.move(id, by: offset) }
        window.onResize = { [weak self] guest, growth in self?.resize(guest, by: growth) }
        return window
    }

    /// Moves the guest's window by as many of its pixels as its window on the Mac was moved by in points.
    private func move(_ id: GuestWindow.ID, by offset: CGVector) {
        guard let list = machine.agent.windows, let guest = list.windows.first(where: { $0.id == id }),
              let screen = NSScreen.screens.first
        else { return }
        let layout = SeamlessLayout(screenFrame: screen.visibleFrame, guestSize: CGSize(width: list.width, height: list.height))
        let target = layout.guestOrigin(of: guest, movedBy: offset)
        machine.agent.moveWindow(id, x: target.x, y: target.y)
    }

    /// Resizes the guest's window by as many of its pixels on each side as its window on the Mac was
    /// made larger by in points, from what it was when that began.
    private func resize(_ guest: GuestWindow, by growth: NSEdgeInsets) {
        guard let list = machine.agent.windows, let screen = NSScreen.screens.first else { return }
        let layout = SeamlessLayout(screenFrame: screen.visibleFrame, guestSize: CGSize(width: list.width, height: list.height))
        let target = layout.guestFrame(of: guest, grownBy: growth)
        machine.agent.resizeWindow(guest.id, x: target.x, y: target.y, width: target.width, height: target.height)
    }

    /// Stacks the Mac's windows as the guest's are, front to back, behind whatever other apps have in
    /// front of them. A window that has only just opened comes forward with the rest.
    private func stack(_ order: [GuestWindow.ID], opened: Set<GuestWindow.ID>) {
        guard order != stacked || !opened.isEmpty else { return }
        stacked = order
        let ordered = order.compactMap { windows[$0] }
        guard let back = ordered.last else { return }
        if !back.isVisible {
            back.orderFront(nil)
        }
        for (window, behind) in zip(ordered.dropLast(), ordered.dropFirst()).reversed() {
            window.order(.above, relativeTo: behind.windowNumber)
        }
    }

    /// Gives the keyboard to the window the guest gave it to, while the app is the one in front.
    private func focus(_ id: GuestWindow.ID?) {
        guard id != focused else { return }
        focused = id
        guard NSApp.isActive, let id, let window = windows[id], !window.isKeyWindow else { return }
        isFocusing = true
        window.makeKeyAndOrderFront(nil)
        isFocusing = false
    }

    /// Someone brought a window forward on the Mac, with Command-` or in Mission Control: the guest
    /// brings its window forward too. A click does that in the guest by itself.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? SeamlessWindow, windows[window.guestID] === window else { return }
        onUse?()
        guard !isFocusing, !window.isGuestFocused else { return }
        if let startMenuShown, ContinuousClock.now - startMenuShown < Self.startMenuGrace { return }
        machine.agent.activateWindow(window.guestID)
    }

    /// Someone went to another app: a menu of the guest's, or its Start menu, closes, as it does when
    /// someone clicks elsewhere in Windows. Left open, it would stay above the other app's windows.
    @objc private func appDidResignActive(_ notification: Notification) {
        guard let list = machine.agent.windows, let front = list.windows.first(where: \.isFocused),
              front.isPopup, windows[front.id] != nil
        else { return }
        Task {
            try? await machine.pressKeys(GuestJob.Keys(keys: ["escape"]))
        }
    }

    private func close(_ ids: Set<GuestWindow.ID>) {
        for id in ids {
            windows.removeValue(forKey: id)?.dismiss()
        }
    }

    // MARK: The guest's screen

    @objc private func screensDidChange() {
        fitGuestToScreen()
        update()
    }

    /// Asks the guest's screen to be the size of the part of the Mac's screen that windows may take.
    private func fitGuestToScreen() {
        guard isRunning, let screen = NSScreen.screens.first else { return }
        let size = SeamlessLayout.displaySize(covering: screen.visibleFrame, backingScale: screen.backingScaleFactor)
        machine.requestDisplaySize(width: size.width, height: size.height, scale: screen.backingScaleFactor)
    }

    /// Ends the session once the machine has stopped or been suspended.
    private func watchState() {
        withObservationTracking {
            _ = machine.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                if self.machine.state.isActive {
                    self.watchState()
                } else {
                    self.onEnd?(nil)
                }
            }
        }
    }
}
