import AppKit
import VMCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Machines keep running without a window; the app stays in the Dock.
        false
    }

    /// Quitting with machines running would cut their power, so offer to suspend or shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let creating = model.creationsInProgress
        if !creating.isEmpty {
            // An installation that is cut short has to start from the beginning.
            let alert = NSAlert()
            alert.messageText = creating.count == 1
                ? "“\(creating[0].name)” is still being created."
                : "\(creating.count) virtual machines are still being created."
            alert.informativeText = "If you quit now, this is cancelled and has to start over."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        for creation in model.creations {
            creation.task?.cancel()
        }
        let active = model.activeMachines
        guard !active.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? "“\(active[0].name)” is still running."
            : "\(active.count) virtual machines are still running."
        alert.informativeText = "Suspend saves their state so they pick up where they left off. Shut Down turns them off without saving state."
        alert.addButton(withTitle: "Suspend and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Shut Down and Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                for machine in active {
                    await machine.suspend()
                    // A machine that can't save its state is stopped instead, so quitting always completes.
                    if machine.state.isActive {
                        await machine.forceStop()
                    }
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            Task {
                for machine in active {
                    await machine.forceStop()
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stopControlServer()
    }

    /// Opening a `.swiftvm` bundle from Finder adds it to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppModel.shared
        for url in urls where url.pathExtension == VMBundle.pathExtension {
            do {
                try model.library.add(VMBundle(url: url))
            } catch {
                model.generalError = VMErrorInfo(title: "Couldn't open “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
    }
}
