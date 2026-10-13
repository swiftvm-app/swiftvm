import Foundation
import Testing
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
    }
}
