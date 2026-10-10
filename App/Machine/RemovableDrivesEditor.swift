import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// The disc and disk images plugged into a machine as USB drives, with controls to attach and eject them.
/// Changes reach a running guest right away.
struct RemovableDrivesEditor: View {
    let machine: VirtualMachine

    private var images: [RemovableImage] { machine.configuration.removableImages }

    /// Drives can change while the machine is shut down or running, but not in between or while suspended.
    private var canChange: Bool {
        guard machine.activity == nil else { return false }
        switch machine.state {
        case .stopped, .running, .paused: return true
        case .suspended, .starting, .restoring, .suspending, .stopping: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if images.isEmpty {
                Text("No disc or disk images are attached.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(images) { image in
                HStack(spacing: 10) {
                    Image(systemName: RemovableImage.isDiscImage(image.url) ? "opticaldisc.fill" : "externaldrive.fill")
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(image.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text((image.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if image.readOnly {
                        Text("Read Only")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Eject \(image.name)", systemImage: "eject") { eject(image) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Eject")
                }
            }
            Button("Attach Disk Image…", systemImage: "plus") { attach() }

            if machine.state == .suspended {
                Text("Resume the virtual machine to change its drives. If it can't resume because an image is gone, discard its saved state from its menu first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!canChange)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["iso", "cdr", "img", "raw", "asif"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose disc images (ISO) or disk images to plug into “\(machine.name)” as USB drives."
        let readOnly = NSButton(checkboxWithTitle: "Protect disk images from changes", target: nil, action: nil)
        readOnly.toolTip = "The guest can read the image but not write to it. Disc images are always protected."
        // A little room around the checkbox, as the panel puts the accessory view edge to edge.
        let accessory = NSStackView(views: [readOnly])
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        let protects = readOnly.state == .on
        Task {
            for url in urls {
                do {
                    try await machine.attachImage(RemovableImage(url: url, readOnly: protects))
                } catch {
                    machine.lastError = VMErrorInfo(title: "Couldn't attach “\(url.lastPathComponent)”", message: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func eject(_ image: RemovableImage) {
        Task {
            do {
                try await machine.ejectImage(image.id)
            } catch {
                machine.lastError = VMErrorInfo(title: "Couldn't eject “\(image.name)”", message: error.localizedDescription)
            }
        }
    }
}

/// The toolbar popover for a machine's removable drives.
struct RemovableDrivesPopover: View {
    let machine: VirtualMachine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disc and Disk Images")
                .font(.headline)

            RemovableDrivesEditor(machine: machine)

            Text("Images appear in the guest as USB drives. Eject a drive in the guest before ejecting it here, or the guest may lose what it was still writing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 400)
    }
}
