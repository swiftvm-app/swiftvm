import AgentControl
import CoreGraphics
import Foundation
import GuestChannel
import VMCore

/// Having a macOS guest let its guest tools read the screen as a tree and act on it.
///
/// macOS takes that from someone at its screen and from nobody else: a switch in System Settings, and
/// the account's password. The app is that someone. It has the machine's own display, mouse and
/// keyboard, and the guest tools, which can't see the screen yet, know where the settings' window is.
/// So the app reads the list for the line that names the guest tools, clicks the switch at its end, and
/// types the password where macOS asks for it.
extension AppModel {
    enum AccessError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let reason): reason
            }
        }
    }

    /// Has macOS in `machine`'s guest let the guest tools read what is on its screen as a tree of its
    /// parts and act on them. Returns once it does, and at once if it did already.
    ///
    /// - Parameter sessionPatience: How long the guest tools in the session of whoever is logged in get
    ///   to answer. They start with a login, which a guest that has only just come up is still at.
    func allowAutomation(on machine: VirtualMachine, password: String, sessionPatience: Duration = .seconds(20)) async throws {
        let name = machine.name
        guard machine.configuration.os.family == .macOS else {
            throw AccessError.failed("Only a macOS guest asks before its screen is read as a tree. “\(name)” needs nothing allowed.")
        }
        guard machine.state == .running else { throw VMError.notRunning(name: name) }
        guard machine.agent.isConnected else { throw GuestJobError.noAgent(name: name) }
        guard machine.agent.offers(GuestFeature.permission) else {
            throw GuestJobError.notOffered(name: name, version: machine.agent.version.map { ShownText.line($0, limit: 32) })
        }
        // The password is typed on the machine's keyboard, and ends with the key that sends it.
        guard !password.isEmpty, password.allSatisfy({ !$0.isNewline && MacKeys.press(typing: $0) != nil }) else {
            throw AccessError.failed("The password has to be typed on the machine's keyboard, which has the keys of a US keyboard. This one has characters that none of them types.")
        }
        guard machinesBeingAllowed.insert(machine.id).inserted else {
            throw AccessError.failed("“\(name)” is being asked already. Try again in a moment.")
        }
        defer { machinesBeingAllowed.remove(machine.id) }

        var state = try await permissionState(of: machine, sessionPatience: sessionPatience)
        if !state.isAllowed {
            // A guest that had nothing to do has turned its display off, and shows no settings on it.
            try await machine.press(.init(keys: ["shift"]))
            state = try await permission(.ask, on: machine)
            do {
                try await answer(for: machine, from: state, password: password)
            } catch {
                _ = try? await permission(.finish, on: machine)
                throw error
            }
            _ = try? await permission(.finish, on: machine)
        }
        automationSetupProblems[machine.id] = nil
    }

    // MARK: Private

    /// What System Settings › Privacy & Security calls the list that has the switch for it.
    private static let listName = "Device Control and Data Access (Accessibility before macOS 27)"

    /// Turns the switch on and gives the password, as often as it takes: a switch that was on for an
    /// older copy of the guest tools goes off at the first click.
    private func answer(for machine: VirtualMachine, from asked: GuestPermissionState, password: String) async throws {
        var state = asked
        for _ in 1...3 {
            guard !state.isAllowed else { return }
            guard let settings = state.settings, settings.count == 4 else {
                throw AccessError.failed("System Settings didn't come up on the screen of “\(machine.name)”.")
            }
            if state.sheet == nil {
                guard let (line, window) = try await listedLine(on: machine, from: settings) else {
                    throw AccessError.failed("System Settings in “\(machine.name)” doesn't show the guest tools on its \(Self.listName) list. If something lies over the window, or the screen is locked, see to that and try again.")
                }
                guard let place = MacGuestTools.switchPlace(onLine: line, of: window, scale: state.scale) else {
                    throw AccessError.failed("The guest tools in “\(machine.name)” gave a place on the screen that couldn't be used.")
                }
                try await machine.pointer(.init(action: .click, x: place.x, y: place.y))
                state = try await waitForPermission(on: machine, for: .seconds(4)) { $0.isAllowed || $0.sheet != nil }
            }
            guard state.sheet != nil, !state.isAllowed else { continue }
            // The question is there before it listens: what is typed while it still slides into
            // place is lost, and the rest is no password.
            try await Task.sleep(for: .milliseconds(1500))
            try await machine.press(.init(text: password, keys: ["Return"]))
            // A password that is taken is taken within a second or two. The question that is still
            // there after that has shaken its head.
            state = try await waitForPermission(on: machine, for: .seconds(6)) { $0.isAllowed }
            if !state.isAllowed, state.sheet == nil {
                state = try await waitForPermission(on: machine, for: .seconds(9)) { $0.isAllowed }
            }
            if !state.isAllowed, state.sheet != nil {
                // Still asking: it shook its head.
                try? await machine.press(.init(keys: ["Escape"]))
                try? await Task.sleep(for: .seconds(1))
                throw AccessError.failed("macOS in “\(machine.name)” didn't take the password. It has to be that of an administrator's account that is logged in at the guest's screen.")
            }
        }
        guard state.isAllowed else {
            throw AccessError.failed("The switch for the guest tools in “\(machine.name)” didn't stay on. In the guest, turn on swiftvm-agent under System Settings › Privacy & Security › \(Self.listName).")
        }
    }

    /// Where the list names the guest tools, and the window it is in. The settings' window may still be
    /// opening or moving, they draw it before its list, and add the guest tools to the list a moment
    /// after they asked: so where the window is is asked again each time, and the list read again.
    private func listedLine(
        on machine: VirtualMachine, from settings: [Int], patience: Duration = .seconds(15)
    ) async throws -> (line: CGRect, window: CGRect)? {
        let deadline = ContinuousClock.now + patience
        var frame = settings
        while true {
            let window = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            // The time is that of the picture, not of reading it: the first reading in the app loads
            // what reads, which has taken as long as the whole patience, and the picture it read was
            // then of a list not yet filled in.
            let takenAt = ContinuousClock.now
            if let image = try await machine.frame().image,
               let line = try await ScreenText.find(MacGuestTools.listedName, in: image, within: window) {
                return (line, window)
            }
            guard takenAt < deadline else { return nil }
            try await Task.sleep(for: .seconds(1))
            if let now = try await permission(.check, on: machine).settings, now.count == 4 {
                frame = now
            }
        }
    }

    private func permission(_ action: GuestJob.Permission.Action, on machine: VirtualMachine) async throws -> GuestPermissionState {
        // Asking waits in the guest for System Settings to open, which a busy guest takes its time over.
        let said = try await machine.collect(.permission(.init(action: action)), patience: 45)
        guard let state = try? JSONDecoder().decode(GuestPermissionState.self, from: said) else {
            throw AccessError.failed("The guest tools in “\(machine.name)” gave an answer that couldn't be read.")
        }
        return state
    }

    /// How things stand, from guest tools that may only just be starting in their session.
    private func permissionState(of machine: VirtualMachine, sessionPatience: Duration) async throws -> GuestPermissionState {
        let deadline = ContinuousClock.now + sessionPatience
        while true {
            do {
                return try await permission(.check, on: machine)
            } catch GuestJobError.refused(let reason) {
                guard ContinuousClock.now < deadline, machine.state == .running else { throw GuestJobError.refused(reason) }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Looks until `condition` holds or the time is up, and returns what was seen last.
    private func waitForPermission(
        on machine: VirtualMachine, for patience: Duration, until condition: (GuestPermissionState) -> Bool
    ) async throws -> GuestPermissionState {
        let deadline = ContinuousClock.now + patience
        while true {
            let state = try await permission(.check, on: machine)
            if condition(state) || ContinuousClock.now >= deadline { return state }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

/// How the guest tools for macOS show in the guest's System Settings.
nonisolated enum MacGuestTools {
    /// The name on the list of what may read the screen: the program's, as the installer puts it there.
    static let listedName = "swiftvm-agent"

    /// How far in from the window's right edge the middle of a line's switch is, in points: the
    /// window's margin, the list's own, and half the switch.
    static let switchInset = 49.0

    /// Where to click to turn the switch of a line: at the line's height, at the end of the list.
    /// Everything is in the display's pixels. `nil` if the guest's geometry can't be used.
    static func switchPlace(onLine line: CGRect, of window: CGRect, scale: Double) -> (x: Int, y: Int)? {
        // The scale and the window are the guest's word. Neither may make a conversion trap on this Mac.
        guard scale.isFinite, scale > 0, window.width.isFinite, window.height.isFinite,
              window.width > 0, window.height > 0, window.contains(line),
              let x = Int(exactly: (window.maxX - switchInset * scale).rounded()),
              let y = Int(exactly: line.midY.rounded()), window.contains(CGPoint(x: x, y: y))
        else { return nil }
        return (x, y)
    }
}
