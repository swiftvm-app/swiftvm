import Foundation
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
