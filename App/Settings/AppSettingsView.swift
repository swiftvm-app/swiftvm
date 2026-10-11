import SwiftUI
import VMControl
import VMCore

/// App-wide settings.
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var toolStatus = CommandLineToolLink.Status.notInstalled
    /// The link is being installed or removed, possibly with a password dialog on the screen.
    @State private var isChangingTool = false
    @State private var toolProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Add machines to ~/.ssh/config", isOn: Binding(
                    get: { model.isSSHIncludeInstalled },
                    set: { model.setSSHIncludeInstalled($0) }
                ))
            } header: {
                Text("SSH")
            } footer: {
                Text("Adds one Include line to your SSH configuration so every virtual machine is reachable by name, for example “ssh ubuntu-26-04”. Nothing else in the file is changed.")
            }

            Section("Network") {
                LabeledContent("Shared Network", value: model.networkManager?.defaultSubnet.description ?? "Unavailable")
                LabeledContent("This Mac", value: model.networkManager?.defaultSubnet.hostAddress.description ?? "Unavailable")
            }

            if let link = model.commandLineToolLink {
                commandLineSection(link)
            }

            if UpdateService.shared.isAvailable {
                updatesSection
            }

            Section("Storage") {
                LabeledContent("Virtual Machines") {
                    Button((model.library.machinesDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        NSWorkspace.shared.open(model.library.machinesDirectory)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                }
                LabeledContent("Downloaded Images") {
                    Button((model.downloader.cacheDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        try? FileManager.default.createDirectory(at: model.downloader.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.downloader.cacheDirectory)
                    }
                    .buttonStyle(.link)
                    .help("Show in Finder")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { toolStatus = model.commandLineToolLink?.status ?? .notInstalled }
        // The link may have been changed from Terminal in the meantime.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            toolStatus = model.commandLineToolLink?.status ?? .notInstalled
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section {
            LabeledContent {
                Button("Check for Updates…") { UpdateService.shared.checkForUpdates() }
                    .disabled(!UpdateService.shared.canCheckForUpdates)
            } label: {
                Text(AppIdentity.current.name)
                Text("Version \(UpdateService.shared.version)")
            }
            Toggle("Automatically download and install updates", isOn: Binding(
                get: { UpdateService.shared.automaticallyDownloadsUpdates },
                set: { UpdateService.shared.setAutomaticallyDownloadsUpdates($0) }
            ))
        } header: {
            Text("Updates")
        } footer: {
            Text("An update is installed when \(AppIdentity.current.name) quits. If virtual machines are running then, you are asked what to do with them first, as you are whenever you quit.")
        }
    }

    // MARK: Command line tool

    private func commandLineSection(_ link: CommandLineToolLink) -> some View {
        Section {
            LabeledContent {
                Button(toolStatus == .installed ? "Uninstall…" : "Install Command Line Tool…") {
                    setToolInstalled(toolStatus != .installed, link: link)
                }
                .disabled(isChangingTool)
            } label: {
                Text("swiftvm")
                Text(toolStatusText(for: link))
            }
        } header: {
            Text("Command Line")
        } footer: {
            if let toolProblem {
                Text(toolProblem).foregroundStyle(.red)
            } else {
                Text("The swiftvm tool creates, starts and connects to virtual machines from Terminal. Installing it puts a link in \(link.linkURL.deletingLastPathComponent().path), for which macOS may ask for an administrator's password. Then try “swiftvm help”.")
            }
        }
    }

    private func toolStatusText(for link: CommandLineToolLink) -> String {
        switch toolStatus {
        case .installed:
            "Installed at \(link.linkURL.path)"
        case .notInstalled:
            "Not installed"
        case .occupied(let target?):
            // Another copy of the app, or one that has been moved or deleted since.
            "\(link.linkURL.path) leads to \((target as NSString).abbreviatingWithTildeInPath). Installing points it at this copy of SwiftVM."
        case .occupied(nil):
            "Something else is at \(link.linkURL.path). Installing replaces it, unless it is a folder."
        }
    }

    private func setToolInstalled(_ installed: Bool, link: CommandLineToolLink) {
        isChangingTool = true
        toolProblem = nil
        Task {
            toolProblem = await model.setCommandLineToolInstalled(installed)
            toolStatus = link.status
            isChangingTool = false
        }
    }
}
