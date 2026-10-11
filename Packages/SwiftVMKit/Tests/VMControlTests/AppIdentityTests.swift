import Foundation
import Testing
@testable import VMControl

@Suite struct AppIdentityTests {
    /// A folder with stand-ins for the app and its development copy.
    private struct Scratch {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-identity-\(UUID().uuidString)")

        /// Makes an app with `identifier` in its `Info.plist`, a program and a tool.
        func makeApp(named name: String, identifier: String?) throws -> URL {
            let app = root.appending(path: "\(name).app")
            for folder in ["Contents/MacOS", "Contents/Helpers"] {
                try FileManager.default.createDirectory(at: app.appending(path: folder), withIntermediateDirectories: true)
            }
            try Data().write(to: app.appending(path: "Contents/MacOS/SwiftVM"))
            try Data().write(to: app.appending(path: "Contents/Helpers/swiftvm"))
            if let identifier {
                let properties = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
                try properties.write(to: app.appending(path: "Contents/Info.plist"))
            }
            return app
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func aProgramGoesWithTheAppItIsIn() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let app = try scratch.makeApp(named: "SwiftVM", identifier: "com.swiftvm.app")
        let copy = try scratch.makeApp(named: "SwiftVM Dev", identifier: "com.swiftvm.app.dev")

        #expect(AppIdentity(ofProgramAt: app.appending(path: "Contents/MacOS/SwiftVM")) == .release)
        #expect(AppIdentity(ofProgramAt: app.appending(path: "Contents/Helpers/swiftvm")) == .release)
        #expect(AppIdentity(ofProgramAt: copy.appending(path: "Contents/MacOS/SwiftVM")) == .development)
        #expect(AppIdentity(ofProgramAt: copy.appending(path: "Contents/Helpers/swiftvm")) == .development)
        #expect(AppIdentity.appBundle(containing: copy.appending(path: "Contents/Helpers/swiftvm"))?.lastPathComponent == "SwiftVM Dev.app")
    }

    @Test func aLinkToTheToolGoesWithTheToolsApp() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let copy = try scratch.makeApp(named: "SwiftVM Dev", identifier: "com.swiftvm.app.dev")
        let fileManager = FileManager.default

        // The link in /usr/local/bin.
        let bin = scratch.root.appending(path: "bin")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appending(path: "swiftvm")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: copy.appending(path: "Contents/Helpers/swiftvm"))
        #expect(AppIdentity(ofProgramAt: link) == .development)

        // A link to the app itself, under a name that says nothing.
        let elsewhere = scratch.root.appending(path: "Elsewhere")
        try fileManager.createSymbolicLink(at: elsewhere, withDestinationURL: copy)
        #expect(AppIdentity(ofProgramAt: elsewhere.appending(path: "Contents/Helpers/swiftvm")) == .development)
    }

    @Test func anythingElseGoesWithTheApp() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        // The tool built on its own, in a build folder.
        let alone = scratch.root.appending(path: "Products/Debug/swiftvm")
        try FileManager.default.createDirectory(at: alone.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: alone)
        #expect(AppIdentity(ofProgramAt: alone) == .release)
        #expect(AppIdentity.appBundle(containing: alone) == nil)
        #expect(AppIdentity(ofProgramAt: nil) == .release)

        // An app under a name of someone else's choosing.
        let renamed = try scratch.makeApp(named: "Fork", identifier: "org.example.fork")
        #expect(AppIdentity(ofProgramAt: renamed.appending(path: "Contents/Helpers/swiftvm")) == .release)
    }

    /// An app that is being replaced has no `Info.plist` for a moment. A development copy started in
    /// that moment must not come out as the app, with the app's machines.
    @Test func anAppThatDoesntSayWhatItIsIsNeither() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let silent = try scratch.makeApp(named: "SwiftVM Dev", identifier: nil)
        #expect(AppIdentity(ofProgramAt: silent.appending(path: "Contents/MacOS/SwiftVM")) == nil)
        #expect(AppIdentity(ofProgramAt: silent.appending(path: "Contents/Helpers/swiftvm")) == nil)

        try Data("not a property list".utf8).write(to: silent.appending(path: "Contents/Info.plist"))
        #expect(AppIdentity(ofProgramAt: silent.appending(path: "Contents/MacOS/SwiftVM")) == nil)
    }

    @Test func eachCopyKeepsItsDataInAFolderOfItsOwn() {
        let app = ControlPaths.applicationSupport(for: .release, environment: [:])
        let copy = ControlPaths.applicationSupport(for: .development, environment: [:])
        #expect(app.lastPathComponent == "SwiftVM")
        #expect(copy.lastPathComponent == "SwiftVM-Dev")
        #expect(app.deletingLastPathComponent().path == URL.applicationSupportDirectory.path)
        #expect(copy.deletingLastPathComponent().path == URL.applicationSupportDirectory.path)

        // SWIFTVM_HOME goes before either, and an empty one counts as none.
        for identity in AppIdentity.allCases {
            #expect(ControlPaths.applicationSupport(for: identity, environment: ["SWIFTVM_HOME": "/tmp/swiftvm-elsewhere"]).path == "/tmp/swiftvm-elsewhere")
            #expect(ControlPaths.applicationSupport(for: identity, environment: ["SWIFTVM_HOME": ""]).lastPathComponent == identity.dataDirectoryName)
        }
    }

    /// The scripts that put the app together write the names down a second time. This holds them to
    /// what the app and the tool go by.
    @Test func theBuildScriptsUseTheSameNames() throws {
        // This file is four folders below the repository: Packages/SwiftVMKit/Tests/VMControlTests.
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repository.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: repository.appending(path: "Config/Info.plist"))
        let properties = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(properties["CFBundleIdentifier"] as? String == AppIdentity.release.bundleIdentifier)
        #expect(properties["CFBundleName"] as? String == AppIdentity.release.name)
        #expect(properties["CFBundleDisplayName"] as? String == AppIdentity.release.name)

        let bundling = try String(contentsOf: repository.appending(path: "scripts/bundle-app.sh"), encoding: .utf8)
        #expect(bundling.contains("identifier=\(AppIdentity.development.bundleIdentifier)\n"))
        #expect(bundling.contains("name=\"\(AppIdentity.development.name)\"\n"))
        #expect(bundling.contains("identifier=\(AppIdentity.release.bundleIdentifier)\n"))
        #expect(bundling.contains("name=\(AppIdentity.release.name)\n"))

        let running = try String(contentsOf: repository.appending(path: "scripts/run-dev.sh"), encoding: .utf8)
        #expect(running.contains("/.build/\(AppIdentity.development.name).app\""))

        // What the scripts take for a copy of SwiftVM, and for its program.
        let shared = try String(contentsOf: repository.appending(path: "scripts/common.sh"), encoding: .utf8)
        #expect(AppIdentity.development.bundleIdentifier == AppIdentity.release.bundleIdentifier + ".dev")
        #expect(shared.contains("== \(AppIdentity.release.bundleIdentifier)(|.dev) ]]"))
        let program = try #require(properties["CFBundleExecutable"] as? String)
        #expect(shared.contains("/Contents/MacOS/\(program)"))
    }
}
