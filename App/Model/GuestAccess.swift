import CoreML
import Foundation
import GuestChannel
import ImageIO
import VMCore
import Vision

/// Having a macOS guest let its guest tools, and agent-desktop through them, do what automation needs:
/// read the screen as a tree and act on it, and record the screen.
///
/// macOS takes that from someone at its screen and from nobody else: a switch in System Settings, and
/// the account's password. The app is that someone. It has the machine's own display, mouse and
/// keyboard (``VirtualMachine/carryOut(_:)``), and the guest tools, which can't see the screen yet,
/// know where the settings' window is. So the app reads the list for the line that names the guest
/// tools, clicks the switch at its end, and types the password where macOS asks for it. The first
/// time agent-desktop records the screen, macOS asks once more, and the app says yes to that too.
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
    /// parts and act on them, and, with guest tools that can ask for it, record the screen for
    /// agent-desktop. Returns once it does, and at once if it did already.
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

        try await allow(.accessibility, on: machine, password: password, sessionPatience: sessionPatience)
        // Older guest tools know only the one switch.
        guard machine.agent.offers(GuestFeature.screenRecordingPermission) else {
            automationSetupProblems[machine.id] = nil
            return
        }
        try await allow(.screenRecording, on: machine, password: password, sessionPatience: sessionPatience)
        if machine.agent.offers(GuestFeature.desktop) {
            try await approveDesktopRecording(on: machine)
        }
        automationSetupProblems[machine.id] = nil
    }

    private func allow(
        _ kind: GuestJob.Permission.Kind, on machine: VirtualMachine, password: String, sessionPatience: Duration
    ) async throws {
        var state = try await permissionState(kind, of: machine, sessionPatience: sessionPatience)
        guard !state.isAllowed else { return }
        // A guest that had nothing to do has turned its display off, and shows no settings on it.
        _ = try await machine.carryOut(.keys(.init(keys: ["shift"])))
        state = try await permission(.ask, kind, on: machine)
        do {
            try await answer(kind, for: machine, from: state, password: password)
        } catch {
            _ = try? await permission(.finish, kind, on: machine)
            throw error
        }
        _ = try? await permission(.finish, kind, on: machine)
    }

    /// agent-desktop records the screen past the system's window picker, which macOS has someone at
    /// the screen agree to the first time it happens. The app has it happen, and agrees, once for each
    /// of the two programs macOS may name. A picture that brings no question shows it is answered.
    private func approveDesktopRecording(on machine: VirtualMachine) async throws {
        for _ in 1...3 {
            guard let alert = try await desktopRecordingQuestion(on: machine) else { return }
            try await agree(to: alert, on: machine)
        }
        guard try await desktopRecordingQuestion(on: machine) == nil else {
            throw AccessError.failed("macOS in “\(machine.name)” keeps asking whether agent-desktop may record the screen. Choose Allow in the guest.")
        }
    }

    /// Has agent-desktop take a picture of the screen, and returns where macOS asks about it, if it does.
    private func desktopRecordingQuestion(on machine: VirtualMachine) async throws -> CGRect? {
        do {
            // Without a path the picture comes back as text, and nothing is left in the guest.
            _ = try await machine.collect(.desktop(.init(arguments: ["screenshot"])), patience: 30)
        } catch GuestJobError.refused {
            // agent-desktop isn't there, for a guest that was offline when the tools were installed:
            // nothing to agree to.
            return nil
        } catch {
            // A picture that failed may still have asked, and one taken while the question is up may fail.
        }
        // The question comes up a while after the picture, later on a guest that has only just started.
        let state = try await waitForPermission(.screenRecording, on: machine, for: .seconds(15)) { $0.alert != nil }
        guard let alert = state.alert, alert.count == 4 else { return nil }
        return CGRect(x: alert[0], y: alert[1], width: alert[2], height: alert[3])
    }

    private func agree(to alert: CGRect, on machine: VirtualMachine) async throws {
        let (button, said) = try await allowButton(in: alert, on: machine)
        guard let button else {
            let quoted = said.isEmpty ? "" : " It says: “\(ShownText.line(said, limit: 160))”"
            throw AccessError.failed("macOS in “\(machine.name)” asked something about recording the screen that the app didn't recognize.\(quoted) Answer it in the guest, then try again.")
        }
        _ = try await machine.carryOut(.pointer(.init(action: .click, x: Int(button.midX.rounded()), y: Int(button.midY.rounded()))))
        // Gone, or followed by the question for the other program, which the next round answers.
        _ = try await waitForPermission(.screenRecording, on: machine, for: .seconds(3)) { $0.alert == nil }
    }

    /// Where the question about recording the screen for agent-desktop has its Allow button, and what
    /// the question said when it wasn't recognized. Its window is there before what is in it has faded
    /// in, so it is read until it says so, for a few seconds.
    private func allowButton(in alert: CGRect, on machine: VirtualMachine) async throws -> (CGRect?, String) {
        let deadline = ContinuousClock.now + .seconds(8)
        var said = ""
        while true {
            try await Task.sleep(for: .milliseconds(700))
            // As for the settings' list: the time is that of the picture, not of reading it.
            let takenAt = ContinuousClock.now
            let picture = try await machine.carryOut(.screenshot)
            if let lines = try? await ScreenText.lines(in: picture, within: alert) {
                said = lines.map(\.text).joined(separator: " ")
                // Only the question about agent-desktop, never one about something else that came up
                // meanwhile. macOS names the program it holds responsible: agent-desktop, or the
                // guest tools that started it.
                let ours = ["agent-desktop", MacGuestTools.listedName].map(ScreenText.letters(of:))
                if lines.contains(where: { line in ours.contains { ScreenText.letters(of: line.text).contains($0) } }),
                   let allow = ScreenText.matchingLine("Allow", among: lines.map(\.text)) {
                    return (lines[allow].frame, said)
                }
            }
            guard takenAt < deadline else { return (nil, said) }
        }
    }

    // MARK: Private

    /// Turns the switch on and gives the password, as often as it takes: a switch that was on for an
    /// older copy of the guest tools goes off at the first click.
    private func answer(
        _ kind: GuestJob.Permission.Kind, for machine: VirtualMachine, from asked: GuestPermissionState, password: String
    ) async throws {
        var state = asked
        for _ in 1...3 {
            guard !state.isAllowed else { return }
            guard let settings = state.settings, settings.count == 4 else {
                throw AccessError.failed("System Settings didn't come up on the screen of “\(machine.name)”.")
            }
            if state.sheet == nil {
                guard let (line, window) = try await listedLine(kind, on: machine, from: settings) else {
                    throw AccessError.failed("System Settings in “\(machine.name)” doesn't show the guest tools on its \(kind.listName) list. If something lies over the window, or the screen is locked, see to that and try again.")
                }
                guard let place = MacGuestTools.switchPlace(onLine: line, of: window, scale: state.scale) else {
                    throw AccessError.failed("The guest tools in “\(machine.name)” gave a place on the screen that couldn't be used.")
                }
                _ = try await machine.carryOut(.pointer(.init(action: .click, x: place.x, y: place.y)))
                state = try await waitForPermission(kind, on: machine, for: .seconds(4)) { $0.isAllowed || $0.sheet != nil }
            }
            guard state.sheet != nil, !state.isAllowed else { continue }
            // The question is there before it listens: what is typed while it still slides into
            // place is lost, and the rest is no password.
            try await Task.sleep(for: .milliseconds(1500))
            _ = try await machine.carryOut(.keys(.init(text: password, keys: ["Return"])))
            // A password that is taken is taken within a second or two. The question that is still
            // there after that has shaken its head.
            state = try await waitForPermission(kind, on: machine, for: .seconds(6)) { $0.isAllowed }
            if !state.isAllowed, state.sheet == nil {
                state = try await waitForPermission(kind, on: machine, for: .seconds(9)) { $0.isAllowed }
            }
            if !state.isAllowed, state.sheet != nil {
                // Still asking: it shook its head.
                _ = try? await machine.carryOut(.keys(.init(keys: ["Escape"])))
                try? await Task.sleep(for: .seconds(1))
                throw AccessError.failed("macOS in “\(machine.name)” didn't take the password. It has to be that of an administrator's account that is logged in at the guest's screen.")
            }
        }
        guard state.isAllowed else {
            throw AccessError.failed("The switch for the guest tools in “\(machine.name)” didn't stay on. In the guest, turn on swiftvm-agent under System Settings › Privacy & Security › \(kind.listName).")
        }
    }

    /// Where the list names the guest tools, and the window it is in. The settings' window may still be
    /// opening or moving, they draw it before its list, and add the guest tools to the list a moment
    /// after they asked: so where the window is is asked again each time, and the list read again.
    private func listedLine(
        _ kind: GuestJob.Permission.Kind, on machine: VirtualMachine, from settings: [Int], patience: Duration = .seconds(15)
    ) async throws -> (line: CGRect, window: CGRect)? {
        let deadline = ContinuousClock.now + patience
        var frame = settings
        while true {
            let window = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            // The time is that of the picture, not of reading it: the first reading in the app loads
            // what reads, which has taken as long as the whole patience, and the picture it read was
            // then of a list not yet filled in.
            let takenAt = ContinuousClock.now
            let picture = try await machine.carryOut(.screenshot)
            if let line = try await ScreenText.find(MacGuestTools.listedName, in: picture, within: window) {
                return (line, window)
            }
            guard takenAt < deadline else { return nil }
            try await Task.sleep(for: .seconds(1))
            if let now = try await permission(.check, kind, on: machine).settings, now.count == 4 {
                frame = now
            }
        }
    }

    private func permission(
        _ action: GuestJob.Permission.Action, _ kind: GuestJob.Permission.Kind, on machine: VirtualMachine
    ) async throws -> GuestPermissionState {
        // Asking waits in the guest for System Settings to open, which a busy guest takes its time over.
        let said = try await machine.collect(.permission(.init(action: action, kind: kind)), patience: 45)
        guard let state = try? JSONDecoder().decode(GuestPermissionState.self, from: said) else {
            throw AccessError.failed("The guest tools in “\(machine.name)” gave an answer that couldn't be read.")
        }
        return state
    }

    /// How things stand, from guest tools that may only just be starting in their session.
    private func permissionState(
        _ kind: GuestJob.Permission.Kind, of machine: VirtualMachine, sessionPatience: Duration
    ) async throws -> GuestPermissionState {
        let deadline = ContinuousClock.now + sessionPatience
        while true {
            do {
                return try await permission(.check, kind, on: machine)
            } catch GuestJobError.refused(let reason) {
                guard ContinuousClock.now < deadline, machine.state == .running else { throw GuestJobError.refused(reason) }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Looks until `condition` holds or the time is up, and returns what was seen last.
    private func waitForPermission(
        _ kind: GuestJob.Permission.Kind, on machine: VirtualMachine, for patience: Duration,
        until condition: (GuestPermissionState) -> Bool
    ) async throws -> GuestPermissionState {
        let deadline = ContinuousClock.now + patience
        while true {
            let state = try await permission(.check, kind, on: machine)
            if condition(state) || ContinuousClock.now >= deadline { return state }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}

extension GuestJob.Permission.Kind {
    /// What System Settings › Privacy & Security calls the list that has the switch for it.
    var listName: String {
        switch self {
        case .accessibility: "Device Control and Data Access (Accessibility before macOS 27)"
        case .screenRecording: "Screen & System Audio Recording"
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
    /// Everything is in the pixels of a screenshot. `nil` if the guest's geometry can't be used.
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

/// Reading what is written on a picture of a screen.
nonisolated enum ScreenText {
    /// Where `text` is written in `picture`, a PNG, inside `area`: the frame of the only line that
    /// says it, in the picture's pixels from its top left corner. `nil` if none or several do.
    static func find(_ text: String, in picture: Data, within area: CGRect) async throws -> CGRect? {
        // Recognition sometimes fails on a picture of a window that is still being drawn. What isn't
        // read is read again with the next picture.
        guard let lines = try? await lines(in: picture, within: area) else { return nil }
        return matchingLine(text, among: lines.map(\.text)).map { lines[$0].frame }
    }

    /// The lines written in `picture`, a PNG, inside `area`, each with its frame in the picture's pixels
    /// from its top left corner.
    static func lines(in picture: Data, within area: CGRect) async throws -> [(text: String, frame: CGRect)] {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(picture as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return []
            }
            let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let area = area.intersection(whole)
            guard !area.isEmpty else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // A program's name is no word of any language.
            request.usesLanguageCorrection = false
            // Vision counts in parts of the picture, upwards from its bottom.
            request.regionOfInterest = CGRect(
                x: area.minX / whole.width, y: 1 - area.maxY / whole.height, width: area.width / whole.width, height: area.height / whole.height
            )
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                // The neural engine's runtime fails at times on a Mac that is short of memory or disk,
                // which a Mac running virtual machines often is. The processor reads the same text.
                guard let processor = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }) else {
                    throw error
                }
                request.setComputeDevice(processor, for: .main)
                try VNImageRequestHandler(cgImage: image).perform([request])
            }
            return (request.results ?? []).map { line in
                let box = line.boundingBox
                let frame = CGRect(
                    x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                    width: box.width * area.width, height: box.height * area.height
                )
                return (line.topCandidates(1).first?.string ?? "", frame)
            }
        }.value
    }

    /// A similar name may be another program, and two matches leave no way to tell which is ours.
    static func matchingLine(_ text: String, among lines: [String]) -> Int? {
        let wanted = letters(of: text)
        guard !wanted.isEmpty else { return nil }
        var found: Int?
        for (index, line) in lines.enumerated() where letters(of: line) == wanted {
            guard found == nil else { return nil }
            found = index
        }
        return found
    }

    /// The letters and digits of a text, which is what reading a picture gets right: a hyphen comes
    /// out as any of three dashes.
    static func letters(of text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
