import Foundation
import Testing
@testable import QEMUEngine

@Suite struct DirectXTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tests-\(UUID().uuidString)")

    /// The QEMU of a build with DXMT and d3dmetal-native.
    private func installation() throws -> QEMUInstallation {
        let installation = QEMUInstallation(
            program: directory.appending(path: "QEMU/bin/qemu-system-aarch64"),
            dataDirectory: directory.appending(path: "QEMU/share"), acceleratesGraphics: true
        )
        try FileManager.default.createDirectory(at: installation.libraryDirectory, withIntermediateDirectories: true)
        try Data().write(to: installation.dxmtLibrary)
        try Data().write(to: installation.d3dMetalLibrary)
        return installation
    }

    /// The start of a Mach-O file with code for the processors `types`: thin for one, universal for more.
    private func machO(_ types: [Int32]) -> Data {
        func little(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
        func big(_ value: UInt32) -> [UInt8] { little(value).reversed() }
        guard types.count > 1 else {
            return Data([0xCF, 0xFA, 0xED, 0xFE] + little(UInt32(bitPattern: types[0])) + [UInt8](repeating: 0, count: 24))
        }
        var bytes = big(0xCAFE_BABE) + big(UInt32(types.count))
        for type in types {
            bytes += big(UInt32(bitPattern: type)) + [UInt8](repeating: 0, count: 16)
        }
        return Data(bytes)
    }

    /// A D3DMetal.framework at `url`, laid out as the Game Porting Toolkit has it.
    @discardableResult
    private func framework(at url: URL, types: [Int32] = [D3DMetal.cpuTypeX86_64], version: String = "3.0") throws -> URL {
        let versionA = url.appending(path: "Versions/A")
        try FileManager.default.createDirectory(at: versionA.appending(path: "Resources"), withIntermediateDirectories: true)
        try machO(types).write(to: versionA.appending(path: "D3DMetal"))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: versionA.appending(path: "Resources/version.plist"))
        try FileManager.default.createSymbolicLink(atPath: url.appending(path: "Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: url.appending(path: "D3DMetal").path, withDestinationPath: "Versions/Current/D3DMetal")
        try FileManager.default.createSymbolicLink(atPath: url.appending(path: "Resources").path, withDestinationPath: "Versions/Current/Resources")
        return url
    }

    @Test func d3dMetalIsUsedOnlyWhereItCanRunAndIsWanted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installation = try installation()
        let d3dMetal = directory.appending(path: "Support/D3DMetal/D3DMetal.framework")
        let ready = DirectXHost(d3dMetalFramework: d3dMetal, hasRosetta: true)

        #expect(installation.directXBackend(on: ready) == .d3dMetal(framework: d3dMetal))
        // D3DMetal is for Intel and runs under Rosetta only.
        #expect(installation.directXBackend(on: DirectXHost(d3dMetalFramework: d3dMetal, hasRosetta: false)) == .dxmt)
        // The user hasn't installed it.
        #expect(installation.directXBackend(on: DirectXHost(hasRosetta: true)) == .dxmt)
        // The user keeps every machine on DXMT.
        #expect(installation.directXBackend(on: DirectXHost(d3dMetalFramework: d3dMetal, hasRosetta: true, prefersDXMT: true)) == .dxmt)
        // A build without d3dmetal-native has nothing to run it with.
        try FileManager.default.removeItem(at: installation.d3dMetalLibrary)
        #expect(installation.directXBackend(on: ready) == .dxmt)
    }

    @Test func eachBackendTellsTheRenderServerWhichHalfAndLibraryToRun() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let installation = try installation()
        let runtime = directory.appending(path: "Runtime")
        let libraries = ["NPT_D3D11_LIBRARY_PATH", "NPT_D3D12_LIBRARY_PATH", "NPT_DXGI_LIBRARY_PATH"]

        let dxmt = installation.environment(in: runtime, directX: .dxmt)
        #expect(dxmt["NPT_BACKEND"] == "dxmt")
        #expect(libraries.allSatisfy { dxmt[$0] == installation.dxmtLibrary.path })
        // The guest is offered Direct3D 12 only by a backend that has it.
        #expect(dxmt["NPT_CAPSET_D3D12"] == nil)
        #expect(dxmt["D3DMETAL_FRAMEWORK_PATH"] == nil)

        let framework = directory.appending(path: "Support/D3DMetal/D3DMetal.framework")
        let d3dMetal = installation.environment(in: runtime, directX: .d3dMetal(framework: framework))
        #expect(d3dMetal["NPT_BACKEND"] == "d3dmetal")
        #expect(libraries.allSatisfy { d3dMetal[$0] == installation.d3dMetalLibrary.path })
        #expect(d3dMetal["NPT_CAPSET_D3D12"] == "1")
        #expect(d3dMetal["D3DMETAL_FRAMEWORK_PATH"] == framework.path)
    }

    @Test func findsD3DMetalInWhatTheGamePortingToolkitBrings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let volume = directory.appending(path: "Game Porting Toolkit")
        let inToolkit = try framework(at: volume.appending(path: "redist/lib/external/D3DMetal.framework"))

        // The toolkit's disk image, its redist folder, and the framework itself.
        #expect(try D3DMetal.locate(in: volume)?.path == inToolkit.path)
        #expect(try D3DMetal.locate(in: volume.appending(path: "redist"))?.path == inToolkit.path)
        #expect(try D3DMetal.locate(in: inToolkit)?.path == inToolkit.path)
        #expect(try D3DMetal.locate(in: directory) == nil)

        // A framework of the name that has no code for Intel isn't the one D3DMetal is.
        let impostor = try framework(at: directory.appending(path: "Other/D3DMetal.framework"), types: [D3DMetal.cpuTypeARM64])
        #expect(throws: D3DMetal.Failure.notForIntel(impostor.path)) { try D3DMetal.locate(in: impostor) }
        // One for both kinds of Mac is.
        let universal = try framework(
            at: directory.appending(path: "Universal/D3DMetal.framework"), types: [D3DMetal.cpuTypeARM64, D3DMetal.cpuTypeX86_64]
        )
        #expect(try D3DMetal.locate(in: universal)?.path == universal.path)
    }

    @Test func keepsACopyOfD3DMetalThatReplacesTheOneBefore() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let support = directory.appending(path: "Support/D3DMetal")
        #expect(D3DMetal.installed(in: support) == nil)
        #expect(throws: D3DMetal.Failure.notFound(directory.path)) { try D3DMetal.install(from: directory, into: support) }
        // The toolkit's own disk image only holds the one with D3DMetal: the user is told to open that.
        let download = directory.appending(path: "Game Porting Toolkit 3.0")
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try Data().write(to: download.appending(path: "Evaluation environment for Windows games 3.0.dmg"))
        #expect(throws: D3DMetal.Failure.insideDiskImage("Evaluation environment for Windows games 3.0.dmg")) {
            try D3DMetal.install(from: download, into: support)
        }

        let first = try framework(at: directory.appending(path: "GPTK 3/redist/lib/external/D3DMetal.framework"), version: "3.0")
        let installed = try D3DMetal.install(from: directory.appending(path: "GPTK 3"), into: support)
        #expect(D3DMetal.installed(in: support) == installed)
        #expect(D3DMetal.version(of: installed) == "3.0")
        // The copy is the app's: the toolkit's disk image can go.
        try FileManager.default.removeItem(at: first)
        #expect(D3DMetal.installed(in: support) == installed)

        try framework(at: directory.appending(path: "GPTK 4/D3DMetal.framework"), version: "4.0")
        #expect(try D3DMetal.install(from: directory.appending(path: "GPTK 4"), into: support) == installed)
        #expect(D3DMetal.version(of: installed) == "4.0")

        try D3DMetal.remove(from: support)
        #expect(D3DMetal.installed(in: support) == nil)
    }
}
