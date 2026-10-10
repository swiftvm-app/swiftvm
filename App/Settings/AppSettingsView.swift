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
}
