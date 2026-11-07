import DiskTools
import Foundation
import Installers
import Testing
import VMControl
import VMCore
@testable import SwiftVM

@MainActor
@Suite struct TemplateCreationTests {
    @Test func concurrentCreationsKeepTheirSSHNamesAndUnfinishedOnesReleaseThem() async throws {
        // Short enough for the app's Unix socket, which is kept in its data folder.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "swiftvm-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory).standardizedFileURL
        let previousHome = ProcessInfo.processInfo.environment["SWIFTVM_HOME"]
        setenv("SWIFTVM_HOME", directory.path, 1)
        defer {
            if let previousHome {
                setenv("SWIFTVM_HOME", previousHome, 1)
            } else {
                unsetenv("SWIFTVM_HOME")
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel.shared
        try #require(model.library.rootDirectory == directory)
        model.stopControlServer()
        model.library.onChange = nil

        let disk = DiskConfiguration(fileName: "disk.img", capacity: 1 << 20, format: .raw)
        let configuration = VMConfiguration(
            name: "Original", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 4 << 30,
            disks: [disk], ssh: SSHConfiguration(alias: "base")
        )
        let bundle = try VMBundle.create(at: model.library.makeStagingBundleURL(), configuration: configuration)
        try Data("disk".utf8).write(to: bundle.diskURL(for: disk))
        let original = try model.library.add(staged: bundle)
        let template = try await model.templates.save(original, named: "Base")

        // The first name needs a suffix because the original holds "base"; the second already has it.
        let first = model.create(TemplateCreateRequest(name: "Base", template: template))
        let second = model.create(TemplateCreateRequest(name: "Base 2", template: template))
        await first.task?.value
        await second.task?.value
        try #require(first.errorMessage == nil)
        try #require(second.errorMessage == nil)
        let copies = model.library.machines.filter { $0.id != original.id }
        #expect(copies.count == 2)
        #expect(Set(model.library.machines.map(\.configuration.ssh.alias)).count == 3)

        // Once the copies are forgotten their aliases are free, not still reserved by their creation.
        for copy in copies {
            try model.library.remove(copy, movingToTrash: false)
        }
        #expect(model.uniqueAlias(for: "Base") == "base-2")

        // A file blocks the staging directory, so creation fails after choosing an alias.
        let staging = VMLibrary.stagingDirectory(in: model.library.machinesDirectory)
        try Data().write(to: staging)
        let failed = model.create(TemplateCreateRequest(name: "Retry", template: template))
        await failed.task?.value
        #expect(failed.errorMessage != nil)
        #expect(model.uniqueAlias(for: "Retry") == "retry")
        model.dismiss(failed)
        try FileManager.default.removeItem(at: staging)

        let cancelled = model.create(TemplateCreateRequest(name: "Retry", template: template))
        model.dismiss(cancelled)
        await cancelled.task?.value
        #expect(!model.library.machines.contains { $0.name == "Retry" })
        #expect(model.uniqueAlias(for: "Retry") == "retry")

        let retry = model.create(TemplateCreateRequest(name: "Retry", template: template))
        await retry.task?.value
        try #require(retry.errorMessage == nil)
        #expect(model.library.machines.first { $0.name == "Retry" }?.configuration.ssh.alias == "retry")

        try await theCommandLineSeesAndFreesTheNamesThatCreationsHold(model: model, template: template)
        try await bridgedMachinesKeepLANAddressesSeparateFromSharedReservations(model: model)
        try await changingMACAddressesKeepsTheBundleAndFirstBootNetworkTogether(model: model)
    }

    private func bridgedMachinesKeepLANAddressesSeparateFromSharedReservations(model: AppModel) async throws {
        let configuration = VMConfiguration(
            name: "Bridged", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [],
            networkInterfaces: [NetworkInterfaceConfiguration(bridgedInterfaceIdentifier: "en7")],
            ssh: SSHConfiguration(alias: "bridged", user: "username")
        )
        let staged = try VMBundle.create(at: model.library.makeStagingBundleURL(), configuration: configuration)
        let machine = try model.addToLibrary(staged: staged)
        defer { try? model.library.remove(machine, movingToTrash: false) }
        // Cloning a bridged template must not allocate an address from the shared subnet.
        #expect(machine.configuration.networkInterfaces[0].ipv4Address == nil)
        try machine.updateConfiguration { $0.networkInterfaces[0].ipv4Address = "10.23.0.99" }
        #expect(model.address(for: machine) == nil)

        let info = await model.handle(ControlRequest(command: .info, machine: machine.id.uuidString))
        #expect(info.machines.first?.details?.bridgedInterfaceIdentifier == "en7")
        #expect(info.machines.first?.address == nil)
        let missing = await model.handle(ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "bridged"))
        #expect(!missing.ok)
        let invalid = await model.handle(ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "unknown"))
        #expect(!invalid.ok)
        #expect(machine.configuration.networkInterfaces[0].bridgedInterfaceIdentifier == "en7")

        let shared = await model.handle(ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "shared"))
        #expect(shared.ok)
        #expect(shared.machines.first?.details?.networkMode == "shared")
        #expect(machine.configuration.networkInterfaces[0].usesSharedNetwork)
        #expect(model.address(for: machine) != nil)
        #expect(model.address(for: machine) != "10.23.0.99")
    }

    private func changingMACAddressesKeepsTheBundleAndFirstBootNetworkTogether(model: AppModel) async throws {
        let configuration = VMConfiguration(
            name: "Custom MAC", os: GuestOS(family: .linux), cpuCount: 2, memorySize: 1 << 30, disks: [],
            networkInterfaces: [NetworkInterfaceConfiguration(macAddress: "02:11:22:33:44:55")],
            ssh: SSHConfiguration(alias: "custom-mac", user: "username"),
            installation: InstallationConfiguration(attachesSeedImage: true)
        )
        let staged = try VMBundle.create(at: model.library.makeStagingBundleURL(), configuration: configuration)
        let seed = CloudInitSeed(
            hostName: "custom-mac", userName: "username", password: "password",
            macAddress: configuration.networkInterfaces[0].macAddress, guestAgentInstaller: nil
        )
        try seed.writeImage(to: staged.seedImageURL)
        let machine = try model.addToLibrary(staged: staged)
        defer { try? model.library.remove(machine, movingToTrash: false) }
        let before = machine.configuration.networkInterfaces[0]
        let snapshot = try await machine.takeSnapshot(named: "Before first boot")
        let request = ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "mac", macAddress: " 02:AA:BB:CC:DD:EE\n")
        let response = await model.handle(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)))
        try #require(response.ok)
        #expect(response.machines.first?.details?.macAddress == "02:aa:bb:cc:dd:ee")
        var expected = before
        expected.macAddress = "02:aa:bb:cc:dd:ee"
        #expect(try machine.bundle.loadConfiguration().networkInterfaces == [expected])
        #expect(try ISOImageBuilder.text(of: "meta-data", in: machine.bundle.seedImageURL) == seed.metaData)
        #expect(try ISOImageBuilder.text(of: "user-data", in: machine.bundle.seedImageURL) == seed.userData)
        let network = try ISOImageBuilder.text(of: "network-config", in: machine.bundle.seedImageURL)
        #expect(network.contains("macaddress: \"02:aa:bb:cc:dd:ee\""))
        #expect(!network.contains(before.macAddress))

        let savedSeed = try Data(contentsOf: machine.bundle.seedImageURL)
        for invalid in ["", "02:11:22:33:44", "02:11:22:33:44:gg", "2:11:22:33:44:55", "+2:11:22:33:44:55", "00:00:00:00:00:00", "01:11:22:33:44:55", "ff:ff:ff:ff:ff:ff"] {
            #expect(throws: VMError.self) { try model.setMACAddress(invalid, for: machine) }
        }
        let missing = await model.handle(ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "mac"))
        #expect(!missing.ok)
        let mixed = await model.handle(ControlRequest(command: .network, machine: machine.id.uuidString, networkMode: "shared", macAddress: "02:11:22:33:44:66"))
        #expect(!mixed.ok)
        #expect(machine.configuration.networkInterfaces == [expected])
        #expect(try Data(contentsOf: machine.bundle.seedImageURL) == savedSeed)

        // A second machine's address is taken, even while that machine is shut down.
        let other = try #require(model.library.machines.first { $0.name == "Original" })
        #expect(throws: VMError.self) { try model.setMACAddress("02:11:22:33:44:66", for: other) }
        try other.updateConfiguration { $0.networkInterfaces = [NetworkInterfaceConfiguration(macAddress: "02:11:22:33:44:66")] }
        #expect(throws: VMError.self) { try model.setMACAddress("02:11:22:33:44:66", for: machine) }
        try await machine.whileStopped(.duplicating) { () -> Void in
            #expect(throws: VMError.self) { try model.setMACAddress("02:11:22:33:44:77", for: machine) }
        }

        // A broken setup disc leaves the address alone, rather than saving a card setup can't find.
        try Data("not an ISO".utf8).write(to: machine.bundle.seedImageURL)
        #expect(throws: (any Error).self) { try model.setMACAddress("02:11:22:33:44:77", for: machine) }
        #expect(machine.configuration.networkInterfaces == [expected])
        try savedSeed.write(to: machine.bundle.seedImageURL)

        // If settings cannot be saved after rewriting the seed, both keep the old address.
        try FileManager.default.removeItem(at: machine.bundle.configurationURL)
        try FileManager.default.createDirectory(at: machine.bundle.configurationURL, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try model.setMACAddress("02:11:22:33:44:77", for: machine) }
        #expect(machine.configuration.networkInterfaces == [expected])
        #expect(try Data(contentsOf: machine.bundle.seedImageURL) == savedSeed)
        try FileManager.default.removeItem(at: machine.bundle.configurationURL)
        try machine.bundle.save(machine.configuration)

        // Snapshots restore the card they were taken with, while the seed is shared between snapshots.
        try await machine.revert(to: snapshot)
        #expect(machine.configuration.networkInterfaces[0].macAddress == before.macAddress)
        let prepare = try #require(model.backendProvider?.prepareMachine)
        try await prepare(machine)
        #expect(try ISOImageBuilder.text(of: "network-config", in: machine.bundle.seedImageURL) == seed.networkConfig)
        #expect(try ISOImageBuilder.text(of: "meta-data", in: machine.bundle.seedImageURL) == seed.metaData)
        #expect(try ISOImageBuilder.text(of: "user-data", in: machine.bundle.seedImageURL) == seed.userData)
        // Removing setup media has always been allowed; neither editing nor starting puts it back.
        try FileManager.default.removeItem(at: machine.bundle.seedImageURL)
        try model.setMACAddress("02:11:22:33:44:77", for: machine)
        try await prepare(machine)
        #expect(try machine.bundle.loadConfiguration().networkInterfaces[0].macAddress == "02:11:22:33:44:77")
        #expect(!FileManager.default.fileExists(atPath: machine.bundle.seedImageURL.path))
    }

    /// A creation holds its name before there is a machine: `list` shows it, and `delete` lets it go,
    /// whether it is still working, as one is that a stopped `swiftvm create` left behind, or failed.
    private func theCommandLineSeesAndFreesTheNamesThatCreationsHold(model: AppModel, template: VMTemplate) async throws {
        let staging = VMLibrary.stagingDirectory(in: model.library.machinesDirectory)
        try Data().write(to: staging)
        let failed = model.create(TemplateCreateRequest(name: "Broken One", template: template))
        await failed.task?.value
        try #require(failed.errorMessage != nil)
        try FileManager.default.removeItem(at: staging)

        let listed = await model.handle(ControlRequest(command: .list))
        #expect(listed.creations?.first { $0.name == "Broken One" }?.error != nil)
        let again = await model.handle(ControlRequest(
            command: .create, create: .init(distribution: "", name: "broken one", template: template.name, start: false)
        ))
        #expect(again.ok == false)
        #expect(again.error?.contains("swiftvm delete 'Broken One'") == true)
        let cleared = await model.handle(ControlRequest(command: .delete, machine: "broken-one"))
        #expect(cleared.ok)
        #expect(!model.isNameTaken("Broken One"))

        // Nothing runs on the main actor until this test waits, so the creation hasn't got anywhere. Its
        // name is the SSH name of "Original", which is the machine that mustn't be deleted for it.
        let pending = model.create(TemplateCreateRequest(name: "Base", template: template))
        let cancelled = await model.handle(ControlRequest(command: .delete, machine: "base"))
        #expect(cancelled.ok)
        #expect(cancelled.note?.hasPrefix("Cancelled") == true)
        #expect(!model.isNameTaken("Base"))
        await pending.task?.value
        #expect(!model.library.machines.contains { $0.name == "Base" })
        #expect(model.library.machines.contains { $0.name == "Original" })
    }
}
