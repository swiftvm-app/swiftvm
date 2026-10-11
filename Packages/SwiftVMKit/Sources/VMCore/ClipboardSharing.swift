import AppKit

/// A clipboard, as far as sharing it goes: what was copied last, as text.
@MainActor
public protocol Clipboard: AnyObject {
    /// Goes up whenever something is copied, by anyone.
    var changeCount: Int { get }
    /// What was copied, if it can be had as text.
    var text: String? { get }
    func setText(_ text: String)
}

/// This Mac's clipboard.
@MainActor
public final class SystemClipboard: Clipboard {
    private let pasteboard = NSPasteboard.general

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }
    public var text: String? { pasteboard.string(forType: .string) }

    public func setText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Keeps this Mac's clipboard and those of the guests that share theirs the same: text copied on the Mac
/// can be pasted in every such guest, and text copied in one of them on the Mac and in the others.
///
/// A guest takes part while its agent is connected and offers to (macOS guests with the guest tools), and
/// its machine has clipboard sharing turned on. Only text is shared, and only what fits in one of the
/// agent's messages.
///
/// macOS has no way to be told that something was copied, so while there is a guest to tell, this looks
/// at the clipboard's counter a couple of times a second and reads the clipboard only when it has moved.
@MainActor
public final class ClipboardSharing {
    private let clipboard: any Clipboard
    private let lookInterval: Duration
    private var guests: [UUID: VirtualMachine] = [:]
    /// The state of the Mac's clipboard that has been dealt with: told to the guests, or put there from one.
    private var seenChangeCount = 0
    private var watch: Task<Void, Never>?
    /// What each guest and the Mac last had in common: a mark of the text that was last sent to it or
    /// came from it. A mark, not the text: nothing that was copied is kept here.
    private var lastShared: [UUID: Int] = [:]

    public init(clipboard: any Clipboard = SystemClipboard(), lookInterval: Duration = .milliseconds(500)) {
        self.clipboard = clipboard
        self.lookInterval = lookInterval
    }

    /// Whether the Mac's clipboard is being watched, which it only is while a guest shares it.
    public var isWatching: Bool { watch != nil }

    /// Takes a machine in or out, as it is now. Call when its agent has connected or gone, and when its
    /// configuration has changed.
    public func update(_ machine: VirtualMachine) {
        let shares = machine.agent.sharesClipboard && machine.configuration.clipboard.isShared
        guard shares != (guests[machine.id] != nil) else { return }
        guard shares else {
            guests[machine.id] = nil
            if guests.isEmpty {
                watch?.cancel()
                watch = nil
            }
            return
        }
        guests[machine.id] = machine
        // A guest that joins gets what was copied on the Mac while it was away. What it had from the
        // Mac already isn't sent again: a guest that comes back from being suspended may have copied
        // something since, a picture say, that this would wipe out. One that has started afresh, or
        // where someone has just logged in, asks for it itself.
        if let text = clipboard.text, !text.isEmpty, lastShared[machine.id] != text.hashValue {
            send(text, to: machine)
        }
        if watch == nil {
            seenChangeCount = clipboard.changeCount
            watch = Task { [weak self, lookInterval] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: lookInterval)
                    guard !Task.isCancelled else { return }
                    self?.look()
                }
            }
        }
    }

    /// Text was copied in a machine's guest.
    public func guest(_ machine: VirtualMachine, didCopy text: String) {
        guard guests[machine.id] != nil, !text.isEmpty else { return }
        lastShared[machine.id] = text.hashValue
        if clipboard.text != text {
            clipboard.setText(text)
        }
        // Putting it there moved the counter. The guest it came from has it already.
        seenChangeCount = clipboard.changeCount
        for (id, other) in guests where id != machine.id {
            send(text, to: other)
        }
    }

    /// A machine's guest asks for what is on the Mac's clipboard: someone has logged in there, with a
    /// clipboard that has nothing from the Mac on it.
    public func guestWantsClipboard(_ machine: VirtualMachine) {
        guard guests[machine.id] != nil, let text = clipboard.text, !text.isEmpty else { return }
        send(text, to: machine)
    }

    private func look() {
        let changeCount = clipboard.changeCount
        guard changeCount != seenChangeCount else { return }
        seenChangeCount = changeCount
        guard let text = clipboard.text, !text.isEmpty else { return }
        for guest in guests.values {
            send(text, to: guest)
        }
    }

    private func send(_ text: String, to machine: VirtualMachine) {
        if machine.agent.sendClipboard(text) {
            lastShared[machine.id] = text.hashValue
        }
    }
}
