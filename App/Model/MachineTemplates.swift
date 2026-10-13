import AppKit
import VMCore

/// Templates: saving a machine as one, and what the app does with those there are.
extension AppModel {
    /// Saves a machine as a template: as it is now, for which it has to be shut down, or as it was at
    /// `snapshot`. On the disk the machine is on that takes no time. To another disk its disks are
    /// copied, which takes a while, and can be called off with ``cancelTemplateSave(of:)``.
    @discardableResult
    func saveTemplate(of machine: VirtualMachine, at snapshot: VMSnapshot? = nil, named name: String? = nil) async throws -> VMTemplate {
        if templateSaves[machine.id] != nil {
            throw VMError.busy(name: machine.name, .savingTemplate)
        }
        // A task of its own, so that the save can be called off whoever is waiting for it.
        let task = Task { try await templates.save(machine, at: snapshot, named: name) }
        templateSaves[machine.id] = task
        defer { templateSaves[machine.id] = nil }
        return try await task.value
    }

    /// Calls off a save that is still copying. Nothing is left of the template.
    func cancelTemplateSave(of machine: VirtualMachine) {
        templateSaves[machine.id]?.cancel()
    }

    func cancelTemplateSaves() {
        templateSaves.values.forEach { $0.cancel() }
    }

    /// The machines that are being saved as templates, which to another disk can take a long time.
    var machinesBeingSavedAsTemplates: [VirtualMachine] {
        library.machines.filter { templateSaves[$0.id] != nil }
    }

    /// Saves a machine as a template for a menu command, under the next free name, and shows the
    /// Templates window: that is where the template turns up and can be given a name, and where it says
    /// so if it couldn't be saved. To another disk the saving takes a while, and whoever has closed
    /// the window by then hears of a failure wherever the machine's errors are shown.
    func saveTemplateReportingErrors(of machine: VirtualMachine, at snapshot: VMSnapshot? = nil) {
        windows.showTemplates()
        isShowingTemplates = true
        Task {
            do {
                try await saveTemplate(of: machine, at: snapshot)
            } catch is CancellationError {
                // Called off by whoever started it.
            } catch {
                let problem = VMErrorInfo(title: "Couldn't save “\(machine.name)” as a template", message: error.localizedDescription)
                if isShowingTemplates {
                    templateProblem = problem
                } else {
                    machine.lastError = problem
                }
            }
        }
    }

    /// A name for a machine made from `template` that nothing else uses: the template's own, or with a
    /// number after it.
    func nameForMachine(from template: VMTemplate) -> String {
        var candidate = template.name
        var counter = 2
        while isNameTaken(candidate) {
            candidate = "\(template.name) \(counter)"
            counter += 1
        }
        return candidate
    }

    /// Keeps templates in `folder` from now on, or in the default folder again with `nil`. Those that
    /// were saved before stay where they are.
    func setTemplatesDirectory(_ folder: URL?) throws {
        try templates.setDirectory(folder)
    }

    func revealInFinder(_ template: VMTemplate) {
        guard let bundle = templates.bundle(of: template) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
    }
}
