import AppKit
import VMCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockPresence.shared.start()
        UpdateService.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Machines keep running without a window; the app stays in the menu bar.
        false
    }

    /// The app was opened again while it runs, from the Finder or Spotlight. With a window open that
    /// comes forward. Without one there is nothing to bring forward but the menu bar item, which someone
    /// who opens the app a second time may not have found: they get the app's settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // A hidden app has its windows too, and gets them back by being shown again.
        guard !sender.isHidden, !DockPresence.shared.hasWindows else { return true }
        AppModel.shared.windows.showAppSettings()
        return false
    }

    /// Whether macOS has put the question of quitting to the app since the app last asked to quit.
    private static var wasAskedToTerminate = false

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
            MainActor.assumeIsolated {
                wasAskedToTerminate = false
                NSApp.terminate(nil)
                // Still here, and never asked: macOS called the quit off by itself, as it does while a
                // sheet is open. A quit for the command-line tool is off with it. Left on, the app
                // would turn every command down as "quitting" for as long as it runs.
                if !wasAskedToTerminate {
                    AppModel.shared.cancelUnattendedQuit()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Quitting with machines running would cut their power, so offer to suspend or shut them down first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.wasAskedToTerminate = true
        let model = AppModel.shared
        let moving = model.machinesBeingMoved
        if !moving.isEmpty, !model.isQuittingUnattended {
            // Copying a machine to another disk is work on its files that isn't over in a moment. It
            // can be called off at no cost: the machine is where it was until it has arrived.
            let alert = NSAlert()
            alert.messageText = moving.count == 1
                ? "“\(moving[0].name)” is still being moved."
                : "\(moving.count) virtual machines are still being moved."
            alert.informativeText = "If you quit now, the move is cancelled and the virtual machine stays where it was."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return stayOpen() }
            model.cancelMoves()
        }
        let converting = model.machinesBeingConverted
        if !converting.isEmpty, !model.isQuittingUnattended {
            // Writing a disk out in another format takes as long as there is on it, and can be called
            // off at no cost as well: the machine goes by the disk it had until the new one is whole.
            let alert = NSAlert()
            alert.messageText = converting.count == 1
                ? "The disk of “\(converting[0].name)” is still being converted."
                : "The disks of \(converting.count) virtual machines are still being converted."
            alert.informativeText = "If you quit now, the conversion is cancelled and the disk stays as it was."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return stayOpen() }
            model.cancelConversions()
        }
        let saving = model.machinesBeingSavedAsTemplates
        if !saving.isEmpty, !model.isQuittingUnattended {
            // Like a move, a template that is saved on another disk is copied there, and can be called
            // off at no cost: the machine it is saved from isn't touched.
            let alert = NSAlert()
            alert.messageText = saving.count == 1
                ? "“\(saving[0].name)” is still being saved as a template."
                : "\(saving.count) virtual machines are still being saved as templates."
            alert.informativeText = "If you quit now, the template isn't saved. The virtual machine stays as it is."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return stayOpen() }
            model.cancelTemplateSaves()
        }
        if model.isWorkingOnMachineFiles {
            // A snapshot, a copy or a resize is over in a moment, and so is a move, a conversion or
            // a template that was called off.
            // Let it finish, then ask again.
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
        if active.contains(where: { !$0.usbDevices.isEmpty }) {
            alert.informativeText += " Either way their USB devices go back to this Mac, as if they were pulled out of the virtual machine."
        }
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

    /// Opening a `.swiftvm` bundle from Finder adds it to the library, and shows its window: the panel in
    /// the menu bar, where it is listed from now on, isn't open to show that anything happened.
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppModel.shared
        for url in urls where url.pathExtension == VMBundle.pathExtension {
            do {
                let machine = try model.library.add(VMBundle(url: url))
                // The app may have been opened with the machine, and then can't open a window yet.
                model.windows.whenReady { model.windows.showMachine(machine.id) }
            } catch {
                model.generalError = VMErrorInfo(title: "Couldn't open “\(url.lastPathComponent)”", message: error.localizedDescription)
            }
        }
    }
}
