import FileSharing
import Foundation
import VMCore
import VMNetworking

/// The shared folders of machines on QEMU, which have no device to share folders through: the app
/// serves them over WebDAV on the virtual network, and the guest's agent maps them as a drive.
extension AppModel {
    /// Where `machine`'s agent finds its shared folders, for a machine that has none through a device.
    /// Starts the server the first time a machine needs it, on the Mac's address on the network.
    func sharedFoldersPlace(for machine: VirtualMachine) -> SharedFoldersPlace? {
        guard machine.configuration.engine == .qemu, let networkManager else { return nil }
        let subnet = networkManager.defaultSubnet
        do {
            try sharedFolderServer.start(on: subnet.hostAddress.description) { peer in
                IPv4Address(peer).map(subnet.contains) ?? false
            }
        } catch {
            machine.notice = VMErrorInfo(title: "The shared folders aren't available in “\(machine.name)”", message: error.localizedDescription)
            return nil
        }
        sharedFolderServer.share(Self.sharedLocations(of: machine.configuration), for: machine.id.uuidString)
        guard let location = sharedFolderServer.location(for: machine.id.uuidString) else { return nil }
        return SharedFoldersPlace(tag: location.absoluteString, mountPoint: GuestIntegration.windowsSharedFoldersDrive)
    }

    /// Hands the server what each machine shares now. A guest that has its drive mapped sees the
    /// change at once: the folders are listed afresh every time it looks. A machine that was deleted
    /// shares nothing any more.
    func syncSharedFolderServer() {
        let machines = library.machines.filter { $0.configuration.engine == .qemu }
        sharedFolderServer.unshare(allBut: Set(machines.map(\.id.uuidString)))
        for machine in machines {
            guard sharedFolderServer.location(for: machine.id.uuidString) != nil else { continue }
            sharedFolderServer.share(Self.sharedLocations(of: machine.configuration), for: machine.id.uuidString)
        }
    }

    /// The machine's shared folders, by the names the guest sees them under: two of the same name are
    /// told apart by a number.
    static func sharedLocations(of configuration: VMConfiguration) -> [SharedLocation] {
        var taken: Set<String> = []
        return configuration.sharedFolders.map { folder in
            let cleaned = folder.name.replacingOccurrences(of: "/", with: "-")
            let base = cleaned.isEmpty ? "Shared" : cleaned
            var name = base
            var counter = 2
            while taken.contains(name) {
                name = "\(base) \(counter)"
                counter += 1
            }
            taken.insert(name)
            return SharedLocation(name: name, url: folder.url, readOnly: folder.readOnly)
        }
    }
}
