import SwiftUI
import VMCore

/// App-wide settings.
struct AppSettingsView: View {
    @Environment(AppModel.self) private var model

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

            if let tool = model.commandLineToolURL {
                Section {
                    CopyableCommand(command: "sudo mkdir -p /usr/local/bin && sudo ln -sf \(AppSettingsView.shellQuoted(tool.path)) /usr/local/bin/swiftvm")
                } header: {
                    Text("Command Line")
                } footer: {
                    Text("The swiftvm tool creates, starts and connects to virtual machines from Terminal. It is inside the app; run this once to put it on your PATH, then try “swiftvm help”.")
                }
            }

            Section("Storage") {
                LabeledContent("Virtual Machines") {
                    Button((model.library.machinesDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        NSWorkspace.shared.open(model.library.machinesDirectory)
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Downloaded Images") {
                    Button((model.downloader.cacheDirectory.path as NSString).abbreviatingWithTildeInPath) {
                        try? FileManager.default.createDirectory(at: model.downloader.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(model.downloader.cacheDirectory)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
