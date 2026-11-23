import AppKit
import VMControl

/// Asks the person at the Mac whether a program may use SwiftVM through `swiftvm serve`. The service
/// keeps the answer.
extension AppModel {
    /// How long the question stays up. The service stops waiting a little after.
    static let permissionQuestionTime: TimeInterval = 110

    /// `true` when allowed, `false` when not, `nil` when nobody answered in time.
    func askPermission(for name: String, at program: String) async -> Bool? {
        windows.bringAppForward()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(name)” to control \(AppIdentity.current.name)’s virtual machines?"
        alert.informativeText = """
            \(program)

            A program that is allowed can start, stop and change your virtual machines, and run commands \
            in them. You can change this later in Settings › Command Line.
            """
        // Not allowing is what Return does.
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        // From the run loop rather than from a block on the main queue, which would hold that queue, and
        // with it the main actor, until the alert is answered. This way the app goes on working meanwhile.
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            RunLoop.main.perform(inModes: [.default]) {
                let timer = Timer(timeInterval: Self.permissionQuestionTime, repeats: false) { _ in
                    NSApp.abortModal()
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                let response = alert.runModal()
                timer.invalidate()
                continuation.resume(returning: response)
            }
        }
        switch answer {
        case .alertFirstButtonReturn: return false
        case .alertSecondButtonReturn: return true
        default: return nil
        }
    }
}
