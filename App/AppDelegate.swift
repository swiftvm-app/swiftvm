import AppKit
import VMCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Machines keep running without a window; the app stays in the Dock.
        false
    }

    /// Asks the app to quit from the run loop, not from the task that wants it to.
    ///
    /// A quit that is asked for inside a task and answered with "later" never finishes. The answer is
    /// given by another task, and no other task runs on the main actor while the first is still inside
    /// `terminate`, waiting for that answer.
    ///
    /// - Returns: The timer that will ask, for a caller that may want to call it off.
    @discardableResult
    static func terminate(after delay: TimeInterval = 0) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Quitting with machines running would cut their power, so offer to suspend or shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.isWorkingOnMachineFiles {
            // A snapshot, a copy or a resize is over in a moment. Let it finish, then ask again.
            Task {
                await model.waitForWorkOnMachineFiles()
                Self.terminate()
            }
            return .terminateCancel
        }
        if model.isQuittingUnattended {
            // The command-line tool asked, so there is nobody to put a question to, and nothing to ask:
            // it was told that machines being created are given up, and none is running.
            guard model.activeMachines.isEmpty else {
                // Not expected, as nothing starts once that quit is agreed to. Staying open costs nothing.
                return stayOpen()
            }
            cancelCreations()
            return .terminateNow
        }
        let creating = model.creationsInProgress
        if !creating.isEmpty {
            let alert = NSAlert()
            alert.messageText = creating.count == 1
                ? "“\(creating[0].name)” is still being created."
                : "\(creating.count) virtual machines are still being created."
            alert.informativeText = "If you quit now, this is cancelled. A download carries on where it stopped the next time you create the virtual machine; an installation starts over."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return stayOpen() }
        }
        cancelCreations()
        let active = model.activeMachines
        guard !active.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? "“\(active[0].name)” is still running."
            : "\(active.count) virtual machines are still running."
        alert.informativeText = "Suspend saves their state so they pick up where they left off. Shut Down turns them off without saving state; a virtual machine without the guest tools is stopped at once."
        alert.addButton(withTitle: "Suspend and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Shut Down and Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.closeDown()
            Task {
                // Something may have begun while the question was on the screen.
                await model.waitForWorkOnMachineFiles()
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
            model.closeDown()
            Task {
                await model.waitForWorkOnMachineFiles()
                await model.shutDownForQuit(active)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return stayOpen()
        }
    }

    /// The answer to a quit that is called off. If the command-line tool asked for a quit of its own, also
    /// while a question was on the screen, that is off as well, and machines may start again.
    private func stayOpen() -> NSApplication.TerminateReply {
        AppModel.shared.cancelUnattendedQuit()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        let model = AppModel.shared
        model.stopControlServer()
        // A download that is cut short here puts away what has arrived, to carry on from there the next
        // time. That happens off the main thread and takes a moment, so wait for it.
        cancelCreations()
        model.downloader.waitForDownloadsToWindUp(timeout: 3)
    }

    private func cancelCreations() {
        for creation in AppModel.shared.creations {
            creation.task?.cancel()
        }
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
