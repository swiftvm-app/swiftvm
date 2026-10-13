import Foundation
import GuestChannel
import ImageIO
import VMCore
import Vision

/// Having a macOS guest let its guest tools read the screen as a tree.
///
/// macOS takes that from someone at its screen and from nobody else: a switch in System Settings, and
/// the account's password. The app is that someone. It has the machine's own display, mouse and
/// keyboard (``VirtualMachine/carryOut(_:)``), and the guest tools, which can't see the screen yet,
/// know where the settings' window is. So the app reads the list for the line that names the guest
/// tools, clicks the switch at its end, and types the password where macOS asks for it.
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
    /// parts, and act on them. Returns once it does, and at once if it did already.
    ///
    /// - Parameter sessionPatience: How long the guest tools in the session of whoever is logged in get
    ///   to answer. They start with a login, which a guest that has only just come up is still at.
    func allowAccessibility(on machine: VirtualMachine, password: String, sessionPatience: Duration = .seconds(20)) async throws {
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
        guard !state.isAllowed else { return }
        // A guest that had nothing to do has turned its display off, and shows no settings on it.
        _ = try await machine.carryOut(.keys(.init(keys: ["shift"])))
        state = try await permission(.ask, on: machine)
        do {
            try await answer(for: machine, from: state, password: password)
        } catch {
            _ = try? await permission(.finish, on: machine)
            throw error
        }
        _ = try? await permission(.finish, on: machine)
    }

    // MARK: Private

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
                let window = CGRect(x: settings[0], y: settings[1], width: settings[2], height: settings[3])
                let picture = try await machine.carryOut(.screenshot)
                guard let line = try await ScreenText.find(MacGuestTools.listedName, in: picture, within: window) else {
                    throw AccessError.failed("System Settings in “\(machine.name)” doesn't show the guest tools on its list. If something lies over the window, or the screen is locked, see to that and try again.")
                }
                let place = MacGuestTools.switchPlace(onLine: line, of: window, scale: state.scale)
                _ = try await machine.carryOut(.pointer(.init(action: .click, x: place.x, y: place.y)))
                state = try await waitForPermission(on: machine, for: .seconds(4)) { $0.isAllowed || $0.sheet != nil }
            }
            guard state.sheet != nil, !state.isAllowed else { continue }
            // The question is there before it listens: what is typed while it still slides into
            // place is lost, and the rest is no password.
            try await Task.sleep(for: .milliseconds(1500))
            _ = try await machine.carryOut(.keys(.init(text: password, keys: ["Return"])))
            // A password that is taken is taken within a second or two. The question that is still
            // there after that has shaken its head.
            state = try await waitForPermission(on: machine, for: .seconds(6)) { $0.isAllowed }
            if !state.isAllowed, state.sheet == nil {
                state = try await waitForPermission(on: machine, for: .seconds(9)) { $0.isAllowed }
            }
            if !state.isAllowed, state.sheet != nil {
                // Still asking: it shook its head.
                _ = try? await machine.carryOut(.keys(.init(keys: ["Escape"])))
                try? await Task.sleep(for: .seconds(1))
                throw AccessError.failed("macOS in “\(machine.name)” didn't take the password. It has to be that of an administrator's account that is logged in at the guest's screen.")
            }
        }
        guard state.isAllowed else {
            throw AccessError.failed("The switch for the guest tools in “\(machine.name)” didn't stay on. In the guest, turn on swiftvm-agent under System Settings › Privacy & Security › Device Control and Data Access, which earlier versions of macOS call Accessibility.")
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
    /// Everything is in the pixels of a screenshot.
    static func switchPlace(onLine line: CGRect, of window: CGRect, scale: Double) -> (x: Int, y: Int) {
        (Int((window.maxX - switchInset * scale).rounded()), Int(line.midY.rounded()))
    }
}

/// Reading what is written on a picture of a screen.
nonisolated enum ScreenText {
    /// Where `text` is written in `picture`, a PNG, inside `area`: the frame of the first line that
    /// says it, in the picture's pixels from its top left corner. `nil` if no line does.
    static func find(_ text: String, in picture: Data, within area: CGRect) async throws -> CGRect? {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(picture as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let area = area.intersection(whole)
            guard !area.isEmpty else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // A program's name is no word of any language.
            request.usesLanguageCorrection = false
            // Vision counts in parts of the picture, upwards from its bottom.
            request.regionOfInterest = CGRect(
                x: area.minX / whole.width, y: 1 - area.maxY / whole.height, width: area.width / whole.width, height: area.height / whole.height
            )
            try VNImageRequestHandler(cgImage: image).perform([request])
            let wanted = letters(of: text)
            for line in request.results ?? [] {
                guard let read = line.topCandidates(1).first, letters(of: read.string).contains(wanted) else { continue }
                let box = line.boundingBox
                return CGRect(
                    x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                    width: box.width * area.width, height: box.height * area.height
                )
            }
            return nil
        }.value
    }

    /// The letters and digits of a text, which is what reading a picture gets right: a hyphen comes
    /// out as any of three dashes.
    static func letters(of text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
