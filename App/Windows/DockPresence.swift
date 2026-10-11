import AppKit

/// Puts the app in the Dock while it has a window open, and takes it out again after the last one.
///
/// The app lives in the menu bar: its `Info.plist` says `LSUIElement`, so it starts without a Dock icon.
/// A guest's display is a window like any other, though, to switch to with Command-Tab and to act on
/// from the menu bar's menus, and both take an app that is in the Dock.
final class DockPresence: NSObject {
    static let shared = DockPresence()

    /// What decides whether a window keeps the app in the Dock.
    struct WindowFacts: Equatable {
        /// On the screen, on another desktop, or minimized into the Dock.
        var isOpen: Bool
        var canBecomeMain: Bool
        /// A panel: an alert, a file dialog, the menu bar panel itself.
        var isPanel: Bool

        init(isOpen: Bool, canBecomeMain: Bool, isPanel: Bool) {
            self.isOpen = isOpen
            self.canBecomeMain = canBecomeMain
            self.isPanel = isPanel
        }

        init(_ window: NSWindow) {
            self.init(
                isOpen: window.isVisible || window.isMiniaturized,
                canBecomeMain: window.canBecomeMain,
                isPanel: window is NSPanel
            )
        }
    }

    /// Whether any of `windows` is one to switch to: a machine, its settings, a new machine being set up.
    /// The menu bar item and what drops down from it aren't, nor is an alert.
    static func wantsDockIcon(for windows: [WindowFacts]) -> Bool {
        windows.contains { $0.isOpen && $0.canBecomeMain && !$0.isPanel }
    }

    /// Whether the app belongs in the Dock: while it has a window to switch to, and after the last one
    /// has closed for as long as it is still the app in front.
    ///
    /// An app that leaves the Dock while it is in front gives the front up with it. macOS then picks
    /// the app to bring forward and goes to the desktop that app is on, wherever the user was: closing a
    /// machine's window threw them onto another desktop. So the app stays where any app stays when its
    /// last window closes, and leaves the Dock once the user has moved on by themselves.
    ///
    /// - Parameter isInDock: Where the app is now. Being in front doesn't put it into the Dock: it can
    ///   be in front with nothing but its panel open, or its question before quitting.
    static func belongsInDock(hasWindows: Bool, isActive: Bool, isInDock: Bool) -> Bool {
        hasWindows || (isInDock && isActive)
    }

    /// Whether the app has a window of its own open right now.
    var hasWindows: Bool {
        Self.wantsDockIcon(for: NSApp.windows.map(WindowFacts.init))
    }

    private var isUpdatePending = false
    /// Until when the app stays in the Dock for a window that was asked for and isn't there yet.
    private var awaitedWindowDeadline: ContinuousClock.Instant?

    /// Starts following the app's windows. Call once, when the app has launched.
    func start() {
        let center = NotificationCenter.default
        let changes = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didUnhideNotification,
            // The moment to leave the Dock, for an app that stayed in front after its last window closed.
            NSApplication.didResignActiveNotification,
        ]
        for name in changes {
            center.addObserver(self, selector: #selector(windowsDidChange), name: name, object: nil)
        }
    }

    /// A window is about to open. The app goes into the Dock first, so that it is an app with menus by
    /// the time it is brought forward: that is when macOS hands the menu bar over. An app that enters
    /// the Dock while it is already in front is known to be left without its menus until it is brought
    /// forward again; whether that can still happen here hasn't been seen.
    func windowWillOpen() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        let patience = Duration.seconds(2)
        awaitedWindowDeadline = .now + patience
        // If nothing comes of it, no window will ever say so.
        Task {
            try? await Task.sleep(for: patience)
            update()
        }
    }

    @objc private func windowsDidChange(_ notification: Notification) {
        // A window that is closing still counts as open while it says so. Look once it has gone, and
        // once for all the windows that change in the same moment.
        guard !isUpdatePending else { return }
        isUpdatePending = true
        Task {
            isUpdatePending = false
            update()
        }
    }

    private func update() {
        // A hidden app has no window on the screen, and is brought back from its Dock icon.
        guard !NSApp.isHidden else { return }
        let hasWindows = hasWindows
        if hasWindows {
            awaitedWindowDeadline = nil
        } else if let deadline = awaitedWindowDeadline, ContinuousClock.now < deadline {
            return
        }
        let isInDock = NSApp.activationPolicy() == .regular
        let belongsInDock = Self.belongsInDock(hasWindows: hasWindows, isActive: NSApp.isActive, isInDock: isInDock)
        if belongsInDock != isInDock {
            NSApp.setActivationPolicy(belongsInDock ? .regular : .accessory)
        }
    }
}
