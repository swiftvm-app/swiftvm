import DiskTools
import Foundation
import Testing
import VMCore
@testable import Installers

@Suite struct SetupScriptTests {
    private static let plasma = """
        #!/bin/sh
        # name: KDE Plasma
        # summary: The KDE Plasma desktop
        # Category: Desktop
        # systems: ubuntu, debian-13
        # memory: 4
        # disk: 24
        # restart: yes
        #
        # Installs Plasma. Note: this takes a while.

        echo "==> Installing"
        # name: Not the name
        apt-get install -y kde-plasma-desktop

        """

    private let ubuntu = LinuxDistribution(id: "ubuntu-26.04", distribution: "ubuntu", name: "Ubuntu 26.04 LTS", summary: "", installers: [])
    private let debian13 = LinuxDistribution(id: "debian-13", distribution: "debian", name: "Debian 13", summary: "", installers: [])
    private let debian12 = LinuxDistribution(id: "debian-12", distribution: "debian", name: "Debian 12", summary: "", installers: [])

    @Test func saysWhatItIsInItsHeader() throws {
        let script = try SetupScript(source: Self.plasma, fileName: "KDE-Plasma.sh")
        #expect(script.id == "kde-plasma")
        #expect(script.name == "KDE Plasma")
        #expect(script.summary == "The KDE Plasma desktop")
        // Keys and the category are read whatever their case.
        #expect(script.category == "desktop")
        #expect(script.isDesktop)
        #expect(script.requiresPassword)
        #expect(script.systems == ["ubuntu", "debian-13"])
        #expect(script.minimumMemoryGigabytes == 4)
        #expect(script.minimumDiskGigabytes == 24)
        #expect(script.restartsWhenDone)
        // What runs in the guest is the file, untouched.
        #expect(script.source == Self.plasma)
    }

    @Test func theHeaderEndsWhereTheProgramStarts() {
        let header = SetupScript.header(of: Self.plasma)
        #expect(header.map(\.key) == ["name", "summary", "category", "systems", "memory", "disk", "restart"])
        // A sentence with a colon in it is a comment, and a key further down is a comment too.
        #expect(!header.contains { $0.value == "this takes a while." || $0.value == "Not the name" })
        // Without a line that names the interpreter the header starts at the top.
        #expect(SetupScript.header(of: "# name: Plain\necho hi\n").map(\.value) == ["Plain"])
        #expect(SetupScript.header(of: "#name:Tight\n##  summary :  Spaced  \n").map(\.value) == ["Tight", "Spaced"])
        #expect(SetupScript.header(of: "echo hi\n# name: Too late\n").isEmpty)
    }

    @Test func aFileWithoutAHeaderIsAScriptAllTheSame() throws {
        let script = try SetupScript(source: "#!/usr/bin/env python3\nprint('hello')\n", fileName: "Install Docker.py")
        #expect(script.id == "install docker")
        #expect(script.name == "Install Docker")
        #expect(script.summary == nil)
        #expect(script.category == nil)
        #expect(!script.isDesktop)
        #expect(!script.requiresPassword)
        #expect(script.systems.isEmpty)
        #expect(script.minimumMemoryGigabytes == nil)
        #expect(!script.restartsWhenDone)
    }

    @Test func whatALaterVersionAddsIsPassedOver() throws {
        let script = try SetupScript(
            source: "# name: Later\n# author: Someone\n# option: autologin | Log in automatically | no\n# image: https://example.com/x.img\necho hi\n",
            fileName: "later.sh"
        )
        #expect(script.name == "Later")
        #expect(script.source.contains("# option: autologin"))
    }

    @Test func aHeaderThatMakesNoSenseIsTurnedDown() {
        #expect(throws: SetupScript.ScriptError.badValue(key: "memory", value: "lots", expected: "a number of GB")) {
            try SetupScript(source: "# memory: lots\necho hi\n", fileName: "a.sh")
        }
        #expect(throws: SetupScript.ScriptError.badValue(key: "disk", value: "0", expected: "a number of GB")) {
            try SetupScript(source: "# disk: 0\necho hi\n", fileName: "a.sh")
        }
        #expect(throws: SetupScript.ScriptError.badValue(key: "restart", value: "maybe", expected: "yes or no")) {
            try SetupScript(source: "# restart: maybe\necho hi\n", fileName: "a.sh")
        }
        #expect((try? SetupScript(source: "# restart: No\necho hi\n", fileName: "a.sh"))?.restartsWhenDone == false)
        #expect((try? SetupScript(source: "# restart: TRUE\necho hi\n", fileName: "a.sh"))?.restartsWhenDone == true)
    }

    @Test func whatIsNotAScriptIsTurnedDown() throws {
        #expect(throws: SetupScript.ScriptError.empty(file: "a.sh")) { try SetupScript(source: " \n\n", fileName: "a.sh") }
        #expect(throws: SetupScript.ScriptError.notText(file: "a.sh")) { try SetupScript(source: "echo\u{0}hi\n", fileName: "a.sh") }
        let large = String(repeating: "# padding\n", count: SetupScript.maximumSize / 10 + 1)
        #expect(throws: SetupScript.ScriptError.tooLarge(file: "a.sh")) { try SetupScript(source: large, fileName: "a.sh") }

        // The same for a file, which isn't read at all when it is too large to be one.
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appending(path: "disk.img")
        try Data(repeating: 0xFF, count: SetupScript.maximumSize + 1).write(to: image)
        #expect(throws: SetupScript.ScriptError.tooLarge(file: "disk.img")) { try SetupScript(contentsOf: image) }
        let binary = directory.appending(path: "program")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binary)
        #expect(throws: SetupScript.ScriptError.notText(file: "program")) { try SetupScript(contentsOf: binary) }
        #expect(throws: (any Error).self) { try SetupScript(contentsOf: directory.appending(path: "missing.sh")) }
        // What has no end to read up to isn't read at all: a folder, or a pipe that would be waited on for good.
        #expect(throws: SetupScript.ScriptError.notAFile(file: directory.lastPathComponent)) { try SetupScript(contentsOf: directory) }
        let pipe = directory.appending(path: "pipe.sh")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: SetupScript.ScriptError.notAFile(file: "pipe.sh")) { try SetupScript(contentsOf: pipe) }
        // A link is as large as what it leads to.
        let link = directory.appending(path: "link.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        #expect(throws: SetupScript.ScriptError.tooLarge(file: "link.sh")) { try SetupScript(contentsOf: link) }

        let file = directory.appending(path: "mine.sh")
        try Data(Self.plasma.utf8).write(to: file)
        let script = try SetupScript(contentsOf: file)
        #expect(script.id == "mine")
        #expect(script.name == "KDE Plasma")
        // Through a link the script is the same, and goes by the link's name.
        let alias = directory.appending(path: "alias.sh")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        #expect(try SetupScript(contentsOf: alias).id == "alias")
    }

    @Test func aFileFromWindowsRunsOnLinux() throws {
        let script = try SetupScript(source: "#!/bin/sh\r\n# name: Mixed\r\necho hi\r\n", fileName: "a.sh")
        #expect(script.source == "#!/bin/sh\n# name: Mixed\necho hi\n")
        #expect(script.name == "Mixed")
    }

    @Test func aNameIsOneLineThatCanBeShown() throws {
        let long = String(repeating: "x", count: 200)
        #expect(try SetupScript(source: "# name: \(long)\necho hi\n", fileName: "a.sh").name.count == SetupScript.maximumNameLength)
        #expect(try SetupScript(source: "# name: Tab\there\u{1B}[31m\necho hi\n", fileName: "a.sh").name == "Tabhere[31m")
        // A name that comes to nothing leaves the file's own.
        #expect(try SetupScript(source: "# name: \u{7}\necho hi\n", fileName: "bell.sh").name == "bell")
        // What a script is asked for by is printed in a terminal, and the name of a file can hold anything.
        #expect(try SetupScript(source: "echo hi\n", fileName: "Red\u{1B}[31m.sh").id == "red[31m")
        // The same for its kind, which is a heading.
        let kind = try SetupScript(source: "# category: Dev\u{7} Tools \(long)\necho hi\n", fileName: "a.sh").category
        #expect(kind?.hasPrefix("dev tools x") == true && kind?.count == SetupScript.maximumCategoryLength)
        #expect(try SetupScript(source: "# category: \u{7}\necho hi\n", fileName: "a.sh").category == nil)
        // And for the systems it names, which are listed too. A few is all there are.
        #expect(try SetupScript(source: "# systems: ubun\u{1B}[2Jtu, debian\u{7}\necho hi\n", fileName: "a.sh").systems == ["ubun[2jtu", "debian"])
        let many = (0..<40).map { "system\($0)" }.joined(separator: " ")
        #expect(try SetupScript(source: "# systems: \(many)\necho hi\n", fileName: "a.sh").systems.count == 16)
    }

    @Test func whatIsSaidAboutAFileCanBeShown() {
        // A complaint is printed in a terminal too, with the file's name and what its header says in it.
        #expect(throws: SetupScript.ScriptError.empty(file: "Red[31m.sh")) {
            try SetupScript(source: " \n", fileName: "Red\u{1B}[31m.sh")
        }
        #expect(throws: SetupScript.ScriptError.badValue(key: "memory", value: "[31mlots", expected: "a number of GB")) {
            try SetupScript(source: "# memory: \u{1B}[31mlots\necho hi\n", fileName: "a.sh")
        }
        #expect(throws: SetupScript.ScriptError.badValue(key: "restart", value: "[2Jmaybe", expected: "yes or no")) {
            try SetupScript(source: "# restart: \u{1B}[2Jmaybe\necho hi\n", fileName: "a.sh")
        }
        let long = String(repeating: "9", count: 500)
        #expect(throws: SetupScript.ScriptError.badValue(key: "disk", value: String(long.prefix(40)), expected: "a number of GB")) {
            try SetupScript(source: "# disk: \(long)\necho hi\n", fileName: "a.sh")
        }
    }

    @Test func knowsWhichSystemsItIsWrittenFor() throws {
        let script = try SetupScript(source: Self.plasma, fileName: "kde-plasma.sh")
        // By family, or by one release of it.
        #expect(script.supports(ubuntu))
        #expect(script.supports(debian13))
        #expect(!script.supports(debian12))
        // A script that names none runs anywhere.
        #expect(try SetupScript(source: "echo hi\n", fileName: "a.sh").supports(debian12))
    }

    @Test func saysWhatAMachineIsShortOf() throws {
        let script = try SetupScript(source: Self.plasma, fileName: "kde-plasma.sh")
        let gigabyte: UInt64 = 1 << 30
        #expect(script.shortfall(memorySize: 4 * gigabyte, diskCapacity: 24 * gigabyte) == nil)
        #expect(script.shortfall(memorySize: 2 * gigabyte, diskCapacity: 64 * gigabyte) == "KDE Plasma needs at least 4 GB of memory.")
        #expect(script.shortfall(memorySize: 8 * gigabyte, diskCapacity: 16 * gigabyte) == "KDE Plasma needs a disk of at least 24 GB.")
        #expect(try SetupScript(source: "echo hi\n", fileName: "a.sh").shortfall(memorySize: 1, diskCapacity: 1) == nil)
    }

    @Test func saysWhyAMachineCannotBeSetUpWithIt() throws {
        let script = try SetupScript(source: Self.plasma, fileName: "kde-plasma.sh")
        let gigabyte: UInt64 = 1 << 30
        let roomy = 64 * gigabyte
        #expect(script.problem(for: ubuntu, memorySize: 8 * gigabyte, diskCapacity: roomy, maximumMemorySize: roomy) == nil)
        // The wrong system comes first: more memory wouldn't help.
        #expect(script.problem(for: debian12, memorySize: 1, diskCapacity: 1, maximumMemorySize: roomy)
            == "KDE Plasma isn't written for Debian 12. It is for: ubuntu, debian-13.")
        #expect(script.problem(for: ubuntu, memorySize: 2 * gigabyte, diskCapacity: roomy, maximumMemorySize: roomy)
            == "KDE Plasma needs at least 4 GB of memory.")
        #expect(script.problem(for: ubuntu, memorySize: 8 * gigabyte, diskCapacity: 16 * gigabyte, maximumMemorySize: roomy)
            == "KDE Plasma needs a disk of at least 24 GB.")

        // What no machine on this Mac can have isn't for the user to raise, and isn't taken on trust
        // from a header either.
        #expect(script.problem(for: ubuntu, memorySize: 2 * gigabyte, diskCapacity: roomy, maximumMemorySize: 2 * gigabyte)
            == "KDE Plasma needs at least 4 GB of memory, which is more than this Mac can give a virtual machine.")
        let greedy = try SetupScript(source: "# name: Greedy\n# memory: 4096\n# disk: 4096\necho hi\n", fileName: "greedy.sh")
        #expect(greedy.problem(for: ubuntu, memorySize: 4096 * gigabyte, diskCapacity: 4096 * gigabyte, maximumMemorySize: roomy)?.hasSuffix("more than this Mac can give a virtual machine.") == true)
        let vast = try SetupScript(source: "# name: Vast\n# disk: 4096\necho hi\n", fileName: "vast.sh")
        #expect(vast.minimumDiskGigabytes.map { $0 <= HostResources.maximumDiskGigabytes } == true)
    }
}

@Suite struct SetupScriptCatalogTests {
    /// A folder of scripts, as a user would keep them, which is gone once `body` is over.
    private func withFolder(_ files: [String: String], _ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appending(path: name))
        }
        try body(folder)
    }

    private static let postgres = "#!/bin/sh\n# name: PostgreSQL\n# category: development\n# systems: debian\n\necho hi\n"

    @Test func bringsTheDesktopsAndOtherTemplates() throws {
        #expect(SetupScriptCatalog.builtIn.map(\.id) == ["gnome", "kde-plasma", "xfce", "cinnamon", "docker", "web-server", "updates"])
        #expect(SetupScriptCatalog.builtIn.filter(\.isDesktop).map(\.id) == ["gnome", "kde-plasma", "xfce", "cinnamon"])
        // Every kind has a heading of its own.
        #expect(SetupScriptCatalog.groups(of: SetupScriptCatalog.builtIn).map(\.title) == ["Desktops", "Development", "Server", "System"])
        let families = Set(DistributionCatalog.quickCreate.flatMap { [$0.distribution, $0.id] })
        for script in SetupScriptCatalog.builtIn {
            #expect(script.origin == .builtIn, "\(script.id)")
            #expect(script.summary?.isEmpty == false, "\(script.id)")
            #expect(script.category != nil, "\(script.id)")
            if script.isDesktop {
                // A desktop starts with the system, which is how it comes up for the first time.
                #expect(script.restartsWhenDone, "\(script.id)")
                #expect(script.minimumMemoryGigabytes != nil && script.minimumDiskGigabytes != nil, "\(script.id)")
            }
            // Each is offered for at least one system the app can make, and for none it can't.
            #expect(!script.systems.isEmpty && Set(script.systems).isSubset(of: families), "\(script.id)")
            #expect(DistributionCatalog.quickCreate.contains(where: script.supports), "\(script.id)")
            // It says where it is, for the app to show.
            #expect(script.source.contains("\necho \"==> "), "\(script.id)")
            #expect(script.source.hasPrefix("#!/bin/sh\n"))
            // The shell at least reads it to the end.
            try ProcessRunner.run("/bin/sh", ["-n"], input: Data(script.source.utf8))
        }
    }

    @Test func keepsTheUsersScriptsInTheirHome() {
        #expect(SetupScriptCatalog.userDirectory.path == NSHomeDirectory() + "/.config/swiftvm/setup-scripts")
    }

    @Test func readsTheScriptsInAFolder() throws {
        try withFolder([
            "postgres.sh": Self.postgres,
            "Web Server.py": "#!/usr/bin/env python3\nprint('hi')\n",
            // What isn't a script: a file nobody is meant to see, what an editor keeps next to a file it
            // has open, and what can't be read as one.
            ".hidden.sh": "echo hi\n",
            "postgres.sh~": "echo old\n",
            "#postgres.sh#": "echo unsaved\n",
            "broken.sh": "# memory: lots\necho hi\n",
            "empty.sh": "\n",
            // One name can't ask for two scripts. The first by its file name has it.
            "postgres.zsh": "#!/bin/zsh\necho hi\n",
        ]) { folder in
            try FileManager.default.createDirectory(at: folder.appending(path: "more"), withIntermediateDirectories: true)
            try Data("echo hi\n".utf8).write(to: folder.appending(path: "more/inner.sh"))

            let (scripts, skipped) = SetupScriptCatalog.userScripts(in: folder)
            #expect(scripts.map(\.id) == ["postgres", "web server"])
            #expect(scripts.map(\.name) == ["PostgreSQL", "Web Server"])
            #expect(scripts.allSatisfy { $0.origin == .library })
            #expect(scripts.first?.category == "development")
            #expect(skipped.map(\.fileName) == ["broken.sh", "empty.sh", "postgres.zsh"])
            #expect(skipped.first?.reason == "The script's header says “memory: lots”, where a number of GB belongs.")
            #expect(skipped.first { $0.fileName == "postgres.zsh" }?.reason == "Another script in the folder is called “postgres” too.")
        }
        // A folder that isn't there holds nothing, and that is nothing to complain of.
        let missing = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)")
        #expect(SetupScriptCatalog.userScripts(in: missing).scripts.isEmpty)
        #expect(SetupScriptCatalog.userScripts(in: missing).skipped.isEmpty)
        #expect(SetupScriptCatalog.all(in: missing) == SetupScriptCatalog.builtIn)
    }

    @Test func readsNoMoreFilesThanAFolderMayHold() throws {
        var files: [String: String] = [:]
        for number in 0...SetupScriptCatalog.maximumFolderFiles {
            files["script-\(number).sh"] = "echo hi\n"
        }
        try withFolder(files) { folder in
            let (scripts, skipped) = SetupScriptCatalog.userScripts(in: folder)
            #expect(scripts.count == SetupScriptCatalog.maximumFolderFiles)
            #expect(skipped.count == 1)
            #expect(skipped.first?.reason.contains("more than \(SetupScriptCatalog.maximumFolderFiles) files") == true)
        }
    }

    @Test func aScriptOfTheUsersStandsNextToTheApps() throws {
        try withFolder(["postgres.sh": Self.postgres]) { folder in
            #expect(SetupScriptCatalog.all(in: folder).map(\.id) == SetupScriptCatalog.builtIn.map(\.id) + ["postgres"])
            #expect(SetupScriptCatalog.script(withID: "Postgres", in: folder)?.origin == .library)
            #expect(SetupScriptCatalog.script(withID: "KDE-Plasma", in: folder)?.name == "KDE Plasma")
            #expect(SetupScriptCatalog.script(withID: "windowmaker", in: folder) == nil)
            // With the files that aren't scripts, the folder is read once for both.
            #expect(SetupScriptCatalog.listing(in: folder).scripts == SetupScriptCatalog.all(in: folder))
            #expect(SetupScriptCatalog.listing(in: folder).skipped.isEmpty)

            // Only what is written for a system is offered for it.
            let debian = try #require(DistributionCatalog.quickCreate.first { $0.distribution == "debian" })
            let ubuntu = try #require(DistributionCatalog.quickCreate.first { $0.distribution == "ubuntu" })
            #expect(SetupScriptCatalog.all(for: debian, in: folder).contains { $0.id == "postgres" })
            #expect(!SetupScriptCatalog.all(for: ubuntu, in: folder).contains { $0.id == "postgres" })
            #expect(SetupScriptCatalog.all(for: ubuntu, in: folder).allSatisfy { $0.supports(ubuntu) })
        }
    }

    @Test func aScriptOfTheUsersTakesThePlaceOfTheAppsByThatName() throws {
        try withFolder(["Xfce.sh": "#!/bin/sh\n# name: My Xfce\n# category: desktop\n# systems: debian\n\necho hi\n"]) { folder in
            let scripts = SetupScriptCatalog.all(in: folder)
            #expect(scripts.map(\.id) == ["gnome", "kde-plasma", "cinnamon", "docker", "web-server", "updates", "xfce"])
            #expect(SetupScriptCatalog.script(withID: "xfce", in: folder)?.name == "My Xfce")
            #expect(SetupScriptCatalog.script(withID: "xfce", in: folder)?.origin == .library)
            // It takes the place for good: where the user's isn't written for a system, the app's isn't offered either.
            let ubuntu = try #require(DistributionCatalog.quickCreate.first { $0.distribution == "ubuntu" })
            #expect(!SetupScriptCatalog.all(for: ubuntu, in: folder).contains { $0.id == "xfce" })
        }
    }

    @Test func findsTheScriptsThatAreAskedFor() throws {
        let debian = try #require(DistributionCatalog.quickCreate.first { $0.distribution == "debian" })
        try withFolder(["postgres.sh": Self.postgres]) { folder in
            let file = folder.deletingLastPathComponent().appending(path: "swiftvm-one-off-\(UUID().uuidString).sh")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data("# name: One Off\necho hi\n".utf8).write(to: file)

            // By name, whatever its case, or as a file by its path from the root. In the order asked.
            let scripts = try SetupScriptCatalog.scripts(for: ["XFCE", file.path, "postgres"], distribution: debian, in: folder)
            #expect(scripts.map(\.name) == ["Xfce", "One Off", "PostgreSQL"])
            #expect(scripts.map(\.origin) == [.builtIn, .file, .library])
            #expect(try SetupScriptCatalog.scripts(for: [], distribution: debian, in: folder).isEmpty)

            // A name nobody knows is answered with the names there are for the system, and how to give a file.
            #expect(throws: SetupScript.ScriptError.unknown(
                name: "mine.sh", system: debian.name, available: SetupScriptCatalog.all(for: debian, in: folder).map(\.id)
            )) {
                try SetupScriptCatalog.scripts(for: ["xfce", "mine.sh"], distribution: debian, in: folder)
            }
            let complaint = SetupScript.ScriptError.unknown(name: "mine.sh", system: "Debian 13", available: ["xfce", "postgres"]).localizedDescription
            #expect(complaint == "No setup script is called “mine.sh”. Available for Debian 13: xfce, postgres. For a file, give its path, as in ./mine.sh.")
            // A name that can't be shown as it is isn't said back as it is.
            #expect(throws: SetupScript.ScriptError.unknown(name: "bad[31m", system: debian.name, available: SetupScriptCatalog.all(for: debian, in: folder).map(\.id))) {
                try SetupScriptCatalog.scripts(for: ["bad\u{1B}[31m"], distribution: debian, in: folder)
            }
            #expect(throws: (any Error).self) {
                try SetupScriptCatalog.scripts(for: [folder.appending(path: "missing.sh").path], distribution: debian, in: folder)
            }
        }
    }

    @Test func listsScriptsByTheirKind() throws {
        func script(_ name: String, _ category: String?) throws -> SetupScript {
            try SetupScript(source: "# name: \(name)\n\(category.map { "# category: \($0)\n" } ?? "")\necho hi\n", fileName: "\(name).sh")
        }
        let scripts = [
            try script("Notes", nil), try script("nginx", "server"), try script("Xfce", "desktop"),
            try script("PostgreSQL", "Development"), try script("GNOME", "desktop"),
        ]
        let groups = SetupScriptCatalog.groups(of: scripts)
        // The desktops first, then the other kinds by name, and last what says nothing about its kind.
        #expect(groups.map(\.title) == ["Desktops", "Development", "Server", "Other"])
        // Within a kind, the order they came in.
        #expect(groups.first?.scripts.map(\.name) == ["Xfce", "GNOME"])
        #expect(groups.flatMap(\.scripts).count == scripts.count)
        // Scripts that are all of no kind need no heading that sets them apart.
        #expect(SetupScriptCatalog.groups(of: [try script("Notes", nil)]).map(\.title) == ["Scripts"])
        #expect(SetupScriptCatalog.groups(of: []).isEmpty)
        // No heading comes twice, whatever the kinds are called: a list tells its parts apart by them.
        let alike = [
            try script("Notes", nil), try script("Odds", "other"), try script("Xfce", "desktop"), try script("LXQt", "Desktops"),
        ]
        let merged = SetupScriptCatalog.groups(of: alike)
        #expect(merged.map(\.title) == ["Desktops", "Other"])
        #expect(merged.map { $0.scripts.map(\.name) } == [["Xfce", "LXQt"], ["Notes", "Odds"]])
        #expect(Set(merged.map(\.id)).count == merged.count)
    }

    @Test func narrowsTheListToWhatWasTyped() throws {
        let builtIn = SetupScriptCatalog.builtIn
        func names(_ filter: String) -> [String] {
            SetupScriptCatalog.groups(of: builtIn, matching: filter).flatMap(\.scripts).map(\.id)
        }
        // Nothing typed, or only spaces, leaves the list as it is.
        #expect(SetupScriptCatalog.groups(of: builtIn, matching: "") == SetupScriptCatalog.groups(of: builtIn))
        #expect(names("  ").count == builtIn.count)
        // By name, whatever the capitals, and by a part of it.
        #expect(names("DOCKER") == ["docker"])
        #expect(names("plas") == ["kde-plasma"])
        // By what the summary says: the Web Server template is nginx.
        #expect(names("nginx") == ["web-server"])
        // By the heading it is listed under, and by the name it is added by.
        #expect(Set(names("desktops")).isSuperset(of: ["gnome", "kde-plasma", "xfce", "cinnamon"]))
        #expect(names("web-server") == ["web-server"])
        // Every word has to be found, each of them anywhere.
        #expect(names("mint desktop") == ["cinnamon"])
        #expect(names("docker nginx").isEmpty)
        #expect(names("no such thing").isEmpty)
        // A heading with nothing left under it is left out, and what is left keeps its heading.
        #expect(SetupScriptCatalog.groups(of: builtIn, matching: "docker").map(\.title) == ["Development"])

        // Accents make no difference, in what was typed or in the script.
        let cafe = try SetupScript(source: "# name: Café Tools\n\necho hi\n", fileName: "cafe.sh")
        #expect(cafe.matches(filter: "cafe"))
        #expect(try SetupScript(source: "# name: Cafe\n\necho hi\n", fileName: "c.sh").matches(filter: "café"))
        // A script of no kind keeps the heading it has in the whole list while the others are filtered out.
        #expect(SetupScriptCatalog.groups(of: builtIn + [cafe], matching: "café").map(\.title) == ["Other"])
        // What is typed is looked for as it is: nothing in it is a pattern.
        #expect(!cafe.matches(filter: ".*"))
    }

    @Test func makesTheFolderForTheUserAlone() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "swiftvm/setup-scripts", directoryHint: .isDirectory)
        #expect(try SetupScriptCatalog.makeUserDirectory(at: folder) == folder)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        // A folder that is there is left as it is, with what is in it.
        try Data(Self.postgres.utf8).write(to: folder.appending(path: "postgres.sh"))
        try SetupScriptCatalog.makeUserDirectory(at: folder)
        #expect(SetupScriptCatalog.userScripts(in: folder).scripts.map(\.id) == ["postgres"])
    }

    /// The scripts the documentation shows are scripts: they can be read as one, say what they are,
    /// and their language at least reads them to the end.
    @Test func theExamplesInTheDocumentationAreScripts() throws {
        // This file is four folders below the repository: Packages/SwiftVMKit/Tests/InstallersTests.
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repository.deleteLastPathComponent()
        }
        let page = try String(contentsOf: repository.appending(path: "docs/features/setup-scripts.md"), encoding: .utf8)
        // Every block of code that starts with the line that names its interpreter.
        var examples: [String] = []
        var block: [Substring]?
        for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") {
                if let lines = block, lines.first?.hasPrefix("#!") == true {
                    examples.append(lines.joined(separator: "\n") + "\n")
                }
                block = block == nil ? [] : nil
            } else {
                block?.append(line)
            }
        }
        #expect(examples.count >= 4)
        var templatesShown = 0
        for example in examples {
            let script = try SetupScript(source: example, fileName: "example")
            #expect(script.name != "example", "\(example.prefix(60))")
            // A template that is shown is shown as it is: the page and the app don't drift apart.
            if let template = SetupScriptCatalog.builtIn.first(where: { $0.name == script.name }) {
                #expect(template.source == example, "\(script.name)")
                templatesShown += 1
            }
            #expect(script.summary != nil, "\(script.name)")
            #expect(example.contains("==> "), "\(script.name)")
            if example.hasPrefix("#!/bin/sh\n") {
                try ProcessRunner.run("/bin/sh", ["-n"], input: Data(example.utf8))
            } else {
                #expect(example.hasPrefix("#!/usr/bin/env python3\n"), "\(script.name)")
                try ProcessRunner.run("/usr/bin/python3", ["-I", "-c", "import ast, sys; ast.parse(sys.stdin.read())"], input: Data(example.utf8))
            }
        }
        // The templates that aren't desktops are short enough to be shown in full, and are.
        #expect(templatesShown == SetupScriptCatalog.builtIn.filter { !$0.isDesktop }.count)
    }

    @Test func savesAScriptTheUserWrote() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "swiftvm-scripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        // The folder needn't be there yet.
        let folder = parent.appending(path: "setup-scripts", directoryHint: .isDirectory)

        // What a new script starts from is one, as it stands.
        let saved = try SetupScriptCatalog.save(source: SetupScriptCatalog.newScriptTemplate, fileName: " My Tools ", in: folder)
        #expect(saved.id == "my tools")
        // It goes by the name it was saved under, which is the one that was typed.
        #expect(saved.name == "My Tools")
        #expect(saved.summary != nil)
        #expect(saved.origin == .library)
        #expect(try String(contentsOf: folder.appending(path: "My Tools.sh"), encoding: .utf8) == SetupScriptCatalog.newScriptTemplate)
        #expect(SetupScriptCatalog.userScripts(in: folder).scripts == [saved])
        // An ending that was given is kept.
        #expect(try SetupScriptCatalog.save(source: "#!/usr/bin/env python3\nprint('hi')\n", fileName: "hello.py", in: folder).id == "hello")
        // What follows a dot in a name isn't taken for an ending, and stays part of what it is asked for by.
        #expect(try SetupScriptCatalog.save(source: "echo hi\n", fileName: "nginx-1.24", in: folder).id == "nginx-1.24")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "nginx-1.24.sh").path))
        // A name of one of the app's own isn't taken by accident.
        #expect(throws: SetupScript.ScriptError.nameOfTemplate("docker")) {
            try SetupScriptCatalog.save(source: "echo mine\n", fileName: "Docker", in: folder)
        }

        // Nothing that is there is written over: not the file, and not the name under another ending.
        #expect(throws: SetupScript.ScriptError.nameTaken("my tools")) {
            try SetupScriptCatalog.save(source: "echo other\n", fileName: "My Tools", in: folder)
        }
        #expect(throws: SetupScript.ScriptError.nameTaken("hello")) {
            try SetupScriptCatalog.save(source: "echo other\n", fileName: "Hello.sh", in: folder)
        }
        #expect(try String(contentsOf: folder.appending(path: "My Tools.sh"), encoding: .utf8) == SetupScriptCatalog.newScriptTemplate)
        // A name is one file in the folder, and nothing that leads out of it or hides in it.
        for name in ["", "  ", "../escape", "a/b", ".hidden", "back~", "a:b", "bell\u{7}", String(repeating: "x", count: 61)] {
            #expect(throws: SetupScript.ScriptError.badFileName(name.trimmingCharacters(in: .whitespaces))) {
                try SetupScriptCatalog.save(source: "echo hi\n", fileName: name, in: folder)
            }
        }
        // What isn't a script isn't saved.
        #expect(throws: SetupScript.ScriptError.badValue(key: "memory", value: "lots", expected: "a number of GB")) {
            try SetupScriptCatalog.save(source: "# memory: lots\necho hi\n", fileName: "broken", in: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["My Tools.sh", "hello.py", "nginx-1.24.sh"])
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "escape.sh").path))
    }
}

@Suite struct SetupScriptSetTests {
    private func script(_ name: String, _ header: String = "") throws -> SetupScript {
        try SetupScript(source: "# name: \(name)\n\(header)\necho \(name)\n", fileName: "\(name).sh")
    }

    private let debian = LinuxDistribution(id: "debian-13", distribution: "debian", name: "Debian 13", summary: "", installers: [])
    private let roomy = (memory: 16 * HostResources.gibibyte, disk: 64 * HostResources.gibibyte)

    @Test func severalScriptsAskOfAMachineWhatTheMostDemandingAsks() throws {
        let desktop = try script("Xfce", "# category: desktop\n# memory: 2\n# disk: 16\n# restart: yes\n")
        let docker = try script("Docker", "# memory: 4\n")
        let plain = try script("Notes")
        let scripts = [desktop, docker, plain]
        #expect(scripts.setupName == "Xfce, Docker, Notes")
        #expect(scripts.requiresPassword)
        #expect(scripts.restartsWhenDone)
        #expect(scripts.minimumMemoryGigabytes == 4)
        #expect(scripts.minimumDiskGigabytes == 16)
        #expect(scripts.problem(for: debian, memorySize: roomy.memory, diskCapacity: roomy.disk) == nil)
        #expect(scripts.problem(for: debian, memorySize: 2 * HostResources.gibibyte, diskCapacity: roomy.disk) == "Docker needs at least 4 GB of memory.")

        // Without any, nothing is asked.
        let none: [SetupScript] = []
        #expect(none.setupName.isEmpty && !none.requiresPassword && !none.restartsWhenDone)
        #expect(none.minimumMemoryGigabytes == nil && none.minimumDiskGigabytes == nil)
        #expect(none.problem(for: debian, memorySize: 1, diskCapacity: 1) == nil)
        #expect(![docker, plain].requiresPassword && ![docker, plain].restartsWhenDone)
    }

    @Test func saysWhyAMachineCannotBeSetUpWithAllOfThem() throws {
        let docker = try script("Docker")
        let forUbuntu = try script("Snaps", "# systems: ubuntu\n")
        #expect([docker, forUbuntu].problem(for: debian, memorySize: roomy.memory, diskCapacity: roomy.disk) == "Snaps isn't written for Debian 13. It is for: ubuntu.")
        #expect([docker, try script("Other"), docker].problem(for: debian, memorySize: roomy.memory, diskCapacity: roomy.disk) == "Docker is listed twice.")
        let many = try (0...SetupScript.maximumPerMachine).map { try script("Script \($0)") }
        #expect(many.problem(for: debian, memorySize: roomy.memory, diskCapacity: roomy.disk) == "A machine is set up with \(SetupScript.maximumPerMachine) scripts at most.")
        #expect(Array(many.dropLast()).problem(for: debian, memorySize: roomy.memory, diskCapacity: roomy.disk) == nil)
    }
}

@Suite struct LinuxUserNameTests {
    @Test func saysWhatIsWrongWithAUserName() {
        #expect(CloudInitSeed.problem(withUserName: "saeed") == nil)
        #expect(CloudInitSeed.problem(withUserName: "build-agent_2") == nil)
        #expect(CloudInitSeed.problem(withUserName: "") != nil)
        #expect(CloudInitSeed.problem(withUserName: "Saeed") != nil)
        #expect(CloudInitSeed.problem(withUserName: "2fast") != nil)
        #expect(CloudInitSeed.problem(withUserName: "j.appleseed") != nil)
        #expect(CloudInitSeed.problem(withUserName: "jürgen") != nil)
        #expect(CloudInitSeed.problem(withUserName: String(repeating: "a", count: 33)) != nil)
        #expect(CloudInitSeed.problem(withUserName: "root") == "Choose a user name other than root.")
    }

    @Test func makesAUserNameOutOfAMacUsers() {
        #expect(CloudInitSeed.userName(from: "saeed") == "saeed")
        #expect(CloudInitSeed.userName(from: "Jane.Doe") == "janedoe")
        #expect(CloudInitSeed.userName(from: "2nd_user") == "nd_user")
        #expect(CloudInitSeed.userName(from: String(repeating: "A", count: 40)).count == 32)
        // What nothing is left of, or what the system keeps for itself, becomes a name that always works.
        for hopeless in ["", "Root", "日本語", "123", "_-_"] {
            #expect(CloudInitSeed.userName(from: hopeless) == "user", "\(hopeless)")
        }
        for name in ["saeed", "Jane.Doe", "2nd_user", "", "Root", "日本語"] {
            #expect(CloudInitSeed.problem(withUserName: CloudInitSeed.userName(from: name)) == nil)
        }
    }
}

@Suite struct CloudInitSetupTests {
    private func seed(with scripts: [SetupScript]) -> CloudInitSeed {
        CloudInitSeed(hostName: "box", instanceID: "abc", userName: "saeed", password: "secret", macAddress: "02:1A:2B:3C:4D:5E", setupScripts: scripts)
    }

    /// What a file in the seed's list of files to write holds, decoded.
    private func contents(of path: String, in userData: String) throws -> String {
        let lines = userData.components(separatedBy: "\n")
        let entry = try #require(lines.firstIndex(of: "  - path: \"\(path)\""))
        #expect(lines[entry + 1] == "    encoding: b64")
        let line = lines[entry + 2]
        #expect(line.hasPrefix("    content: \"") && line.hasSuffix("\""))
        let data = try #require(Data(base64Encoded: String(line.dropFirst("    content: \"".count).dropLast())))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func carriesTheScriptAndWhatRunsIt() throws {
        let script = try #require(SetupScriptCatalog.builtIn.first { $0.id == "kde-plasma" })
        let text = seed(with: [script]).userData

        // The script arrives byte for byte, next to its name, its runner, the runner's settings and the unit.
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/1", in: text) == script.source)
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/1.name", in: text) == "KDE Plasma\n")
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/run.sh", in: text) == (try LinuxGuestAgent.resource("setup-run.sh")))
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/settings", in: text) == "name=KDE Plasma\nrestart=yes\nuser=saeed\n")
        #expect(try contents(of: "/etc/systemd/system/swiftvm-setup.service", in: text) == (try LinuxGuestAgent.resource("swiftvm-setup.service")))
        let lines = text.components(separatedBy: "\n")
        let entry = try #require(lines.firstIndex(of: "  - path: \"/usr/local/lib/swiftvm/setup/scripts/1\""))
        // The script is the administrator's alone to read: it may hold what isn't everyone's.
        #expect(lines[entry + 3] == "    permissions: \"0700\"")
        // One list of files, one list of commands.
        #expect(text.components(separatedBy: "write_files:").count == 2)
        #expect(text.components(separatedBy: "runcmd:").count == 2)

        // The setup is scheduled before the guest agent is installed, so that the agent's first word
        // about it is that it is to come. The agent's installer stays the last thing to run.
        let schedule = try #require(lines.firstIndex(of: "  - \"sh /usr/local/lib/swiftvm/setup/run.sh --schedule || true\""))
        let agent = try #require(lines.firstIndex(of: "  - \"sh /usr/local/lib/swiftvm/install.sh || true\""))
        #expect(schedule < agent)
        #expect(text.hasSuffix("  - \"sh /usr/local/lib/swiftvm/install.sh || true\"\n"))
    }

    @Test func carriesSeveralScriptsInTheirOrder() throws {
        let xfce = try #require(SetupScriptCatalog.builtIn.first { $0.id == "xfce" })
        let docker = try #require(SetupScriptCatalog.builtIn.first { $0.id == "docker" })
        let text = seed(with: [xfce, docker]).userData
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/1", in: text) == xfce.source)
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/2", in: text) == docker.source)
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/2.name", in: text) == "Docker\n")
        #expect(!text.contains("/usr/local/lib/swiftvm/setup/scripts/3"))
        // What all of them set up, and a restart because one of them asks for it.
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/settings", in: text) == "name=Xfce, Docker\nrestart=yes\nuser=saeed\n")
        // The runner, its settings and the unit travel once, and the setup is scheduled once.
        #expect(text.components(separatedBy: "/usr/local/lib/swiftvm/setup/run.sh\"\n").count == 2)
        #expect(text.components(separatedBy: "--schedule").count == 2)
        // The other way round, they run the other way round.
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/1", in: seed(with: [docker, xfce]).userData) == docker.source)
    }

    @Test func aMachineWithoutAScriptIsAsItWas() {
        let text = seed(with: []).userData
        #expect(!text.contains("setup"))
        #expect(text == CloudInitSeed(hostName: "box", instanceID: "abc", userName: "saeed", password: "secret", macAddress: "02:1A:2B:3C:4D:5E").userData)
    }

    @Test func whatTheRunnerIsToldFitsOnALine() throws {
        let script = try SetupScript(source: "# name: Odd $(name) `here`\necho hi\n", fileName: "odd.sh")
        #expect(LinuxGuestSetup.settings(for: [script], userName: "sa\need") == "name=Odd $(name) `here`\nrestart=no\nuser=saeed\n")
        // The same for the name the runner says while the script runs.
        let broken = try SetupScript(source: "echo hi\n", fileName: "a.sh")
        var odd = broken
        odd.name = "Two\nlines"
        #expect(try LinuxGuestSetup.files(for: [odd], userName: "saeed")[1].contents == "Twolines\n")
    }

    @Test func aCopyOfTheMachineKeepsTheScriptAndDoesNotRunItAgain() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "swiftvm-seed-\(UUID().uuidString).iso")
        defer { try? FileManager.default.removeItem(at: url) }
        let script = try #require(SetupScriptCatalog.builtIn.first { $0.id == "xfce" })
        try seed(with: [script]).writeImage(to: url)

        try CloudInitSeed.reissue(at: url, hostName: "box-copy", macAddress: "02:AA:BB:CC:DD:EE", instanceID: "new")
        let userData = try ISOImageBuilder.text(of: "user-data", in: url)
        #expect(try contents(of: "/usr/local/lib/swiftvm/setup/scripts/1", in: userData) == script.source)
        #expect(userData.contains("  - \"sh /usr/local/lib/swiftvm/setup/run.sh --schedule || true\"\n"))
        // What keeps the copy from setting itself up again is in the runner: it leaves a disk alone
        // that a setup has been scheduled on before.
        #expect(try LinuxGuestAgent.resource("setup-run.sh").contains("[ ! -e \"$state/status\" ] || exit 0"))
    }
}

/// The runner, run on this Mac with a `systemctl` that only writes down what it is asked.
@Suite struct LinuxGuestSetupRunnerTests {
    /// A guest's folders, as far as the runner goes into them.
    private final class Guest {
        let root = FileManager.default.temporaryDirectory.appending(path: "swiftvm-setup-\(UUID().uuidString)")
        var home: URL { root.appending(path: "home") }
        var state: URL { root.appending(path: "state") }
        var log: URL { root.appending(path: "setup.log") }
        private var tools: URL { root.appending(path: "bin") }
        private var calls: URL { root.appending(path: "systemctl.calls") }

        /// A guest with one script, which goes by the name the settings give the whole setup.
        convenience init(script: String, settings: String = "name=KDE Plasma\nrestart=no\nuser=saeed\n") throws {
            let name = settings.split(separator: "\n").first { $0.hasPrefix("name=") }.map { String($0.dropFirst(5)) } ?? ""
            try self.init(scripts: [(name, script)], settings: settings)
        }

        /// A guest with several scripts, each with what it calls itself, in the order they run.
        init(scripts: [(name: String, text: String)], settings: String) throws {
            let fileManager = FileManager.default
            for directory in [home.appending(path: "scripts"), tools] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for (index, script) in scripts.enumerated() {
                try Data(script.text.utf8).write(to: self.script(index + 1))
                try Data("\(script.name)\n".utf8).write(to: home.appending(path: "scripts/\(index + 1).name"))
            }
            try Data(settings.utf8).write(to: home.appending(path: "settings"))
            let systemctl = tools.appending(path: "systemctl")
            try Data("#!/bin/sh\necho \"$*\" >> '\(calls.path)'\n".utf8).write(to: systemctl)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemctl.path)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// The shell the guests run the runner with, where this Mac has it: theirs is dash, and what
        /// only bash takes would pass here and fail there.
        static let shell = FileManager.default.isExecutableFile(atPath: "/bin/dash") ? "/bin/dash" : "/bin/sh"

        /// Runs the runner and returns its exit status.
        @discardableResult
        func run(_ arguments: [String] = []) throws -> Int32 {
            let runner = try #require(LinuxGuestAgent.resourceURL("setup-run.sh"))
            let environment = [
                "PATH": "\(tools.path):/usr/bin:/bin",
                "SWIFTVM_SETUP_HOME": home.path,
                "SWIFTVM_SETUP_STATE": state.path,
                "SWIFTVM_SETUP_LOG": log.path,
            ]
            do {
                try ProcessRunner.run(Self.shell, [runner.path] + arguments, environment: environment)
                return 0
            } catch let failure as ProcessRunner.Failure {
                return failure.output.status
            }
        }

        func text(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        /// Puts a stand-in for a tool of the guest's in the runner's way, which notes down how it is called.
        func addTool(_ name: String) throws {
            let tool = tools.appending(path: name)
            try Data("#!/bin/sh\necho \"\(name) $*\" >> '\(calls.path)'\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }

        /// Where the script that runs as number `number` is.
        func script(_ number: Int) -> URL { home.appending(path: "scripts/\(number)") }

        /// The numbers of the scripts that are on record as having come to their end.
        var done: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: state.appending(path: "done").path)) ?? []).sorted() }

        var status: String { text(state.appending(path: "status")) }
        var step: String { text(state.appending(path: "step")) }
        var systemctlCalls: [String] { text(calls).split(separator: "\n").map(String.init) }
        var attemptsLeftBehind: Bool { FileManager.default.fileExists(atPath: state.appending(path: "attempts").path) }
    }

    @Test func schedulesTheSetupOnce() throws {
        let guest = try Guest(script: "echo hi\n")
        #expect(try guest.run(["--schedule"]) == 0)
        // The agent can say that a setup is to come before the script has started.
        #expect(guest.status == "state=pending\nname=KDE Plasma\n")
        #expect(guest.systemctlCalls == ["daemon-reload", "enable swiftvm-setup.service", "start --no-block swiftvm-setup.service"])
        // The script itself hasn't run.
        #expect(guest.text(guest.log).isEmpty)

        // A copy of the machine asks again, on a disk where that has happened: nothing is done.
        #expect(try guest.run(["--schedule"]) == 0)
        #expect(guest.systemctlCalls.count == 3)
        #expect(guest.status == "state=pending\nname=KDE Plasma\n")
    }

    @Test func runsTheScriptAndSaysHowItWent() throws {
        let guest = try Guest(script: """
            #!/bin/sh
            echo "==> Getting ready"
            echo "for $SWIFTVM_USER, without questions: $DEBIAN_FRONTEND"
            echo "a complaint" >&2
            echo "==> Installing KDE Plasma"
            echo "almost ==> not a step"

            """)
        #expect(try guest.run() == 0)
        #expect(guest.status == "state=finished\nname=KDE Plasma\n")
        // The step is the last one the script named.
        #expect(guest.step == "Installing KDE Plasma\n")
        // Everything it printed is kept, in order, whichever way it was printed.
        let log = guest.text(guest.log)
        #expect(log.contains("==> Getting ready\nfor saeed, without questions: noninteractive\na complaint\n==> Installing KDE Plasma\nalmost ==> not a step\n"))
        #expect(log.contains("KDE Plasma, attempt 1 ===="))
        // While it ran it was to start with the system, and now it is over: not started again, and
        // nothing restarted that didn't ask for it.
        #expect(guest.systemctlCalls == ["enable swiftvm-setup.service", "disable swiftvm-setup.service"])
        #expect(!guest.attemptsLeftBehind)
        // Nothing half written is left behind, and what it printed is the administrator's to read.
        #expect(try FileManager.default.contentsOfDirectory(atPath: guest.state.path).sorted() == ["apt.conf", "done", "status", "step"])
        #expect(guest.done == ["1"])
        #expect(try FileManager.default.attributesOfItem(atPath: guest.log.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func restartsTheGuestForAScriptThatAsksForIt() throws {
        let guest = try Guest(script: "echo hi\n", settings: "name=Xfce\nrestart=yes\nuser=saeed\n")
        #expect(try guest.run() == 0)
        #expect(guest.status == "state=finished\nname=Xfce\n")
        // Only once everything is written down.
        #expect(guest.systemctlCalls == ["enable swiftvm-setup.service", "disable swiftvm-setup.service", "--no-block reboot"])
    }

    @Test func aScriptThatFailsIsNotRestartedAfter() throws {
        let guest = try Guest(script: "echo '==> Trying'\nexit 7\n", settings: "name=Xfce\nrestart=yes\nuser=saeed\n")
        #expect(try guest.run() == 7)
        #expect(guest.status == "state=failed\nname=Xfce\n")
        // Where it failed stays on record.
        #expect(guest.step == "Trying\n")
        #expect(guest.text(guest.log).contains("stopped with an error (exit status 7)"))
        #expect(guest.systemctlCalls == ["enable swiftvm-setup.service", "disable swiftvm-setup.service"])

        // Run again by hand, it gets a fresh start. While it runs it starts with the system again:
        // a machine that is turned off under it carries on the next time, as on its first start.
        try Data("echo '==> Second try'\nsystemctl is-this-enabled-by-now\n".utf8).write(to: guest.script(1))
        #expect(try guest.run() == 0)
        #expect(guest.status == "state=finished\nname=Xfce\n")
        #expect(guest.text(guest.log).contains("Xfce, attempt 1 ====\n==> Second try\n"))
        // The script that worked this time asked for a restart, and gets it.
        #expect(guest.systemctlCalls.suffix(4) == [
            "enable swiftvm-setup.service", "is-this-enabled-by-now", "disable swiftvm-setup.service", "--no-block reboot",
        ])
    }

    @Test func runsAScriptInItsOwnLanguage() throws {
        let guest = try Guest(script: "#!/usr/bin/python3 -I\nprint('==> From Python')\n")
        #expect(try guest.run() == 0)
        #expect(guest.step == "From Python\n")
    }

    @Test func doesNotWaitForWhatTheScriptLeftRunning() throws {
        // Something started in the background holds on to the script's output for good.
        let guest = try Guest(script: "echo '==> Starting a service'\nsleep 600 &\necho $! > \"$SWIFTVM_SETUP_STATE/service\"\necho started\n")
        let start = Date()
        #expect(try guest.run() == 0)
        #expect(Date().timeIntervalSince(start) < 60)
        #expect(guest.status == "state=finished\nname=KDE Plasma\n")
        #expect(guest.text(guest.log).contains("==> Starting a service\nstarted\n"))
        // In a guest, systemd clears away what a unit leaves behind. Here the test does.
        let service = try #require(Int32(guest.text(guest.state.appending(path: "service")).trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(service, SIGTERM)
    }

    @Test func givesUpOnAScriptThatIsCutShortEveryTime() throws {
        let guest = try Guest(script: "echo hi\n")
        try FileManager.default.createDirectory(at: guest.state, withIntermediateDirectories: true)
        // Twice the machine went down under it. The third start is still made.
        try Data("2\n".utf8).write(to: guest.state.appending(path: "attempts"))
        #expect(try guest.run() == 0)
        #expect(guest.text(guest.log).contains("attempt 3 ===="))
        #expect(!guest.attemptsLeftBehind)

        // Three times, as a script does that restarts the system itself: that is taken for an answer.
        let stuck = try Guest(script: "echo hi\n")
        try FileManager.default.createDirectory(at: stuck.state, withIntermediateDirectories: true)
        try Data("3\n".utf8).write(to: stuck.state.appending(path: "attempts"))
        try Data().write(to: stuck.state.appending(path: "begun"))
        try Data("state=running\nname=KDE Plasma\n".utf8).write(to: stuck.state.appending(path: "status"))
        try stuck.addTool("dpkg")
        #expect(try stuck.run() == 1)
        #expect(stuck.status == "state=failed\nname=KDE Plasma\n")
        #expect(stuck.text(stuck.log).contains("never came to its end"))
        #expect(!stuck.text(stuck.log).contains("\nhi\n"))
        #expect(stuck.systemctlCalls.last == "disable swiftvm-setup.service")
        #expect(!stuck.attemptsLeftBehind)

        // Started by hand after that, it gets its three starts anew, and the package manager is seen to
        // first: the starts that were cut short may have left it in the middle of its work.
        #expect(try stuck.run() == 0)
        #expect(stuck.text(stuck.log).contains("KDE Plasma, attempt 1 ====\nhi\n"))
        #expect(stuck.systemctlCalls.filter { $0.hasPrefix("dpkg") }.count == 1)
        #expect(stuck.status == "state=finished\nname=KDE Plasma\n")
        // And nothing of it is left to be seen to a second time.
        #expect(try FileManager.default.contentsOfDirectory(atPath: stuck.state.path).sorted() == ["apt.conf", "done", "status", "step"])
    }

    @Test func runsSeveralScriptsInTheirOrder() throws {
        let guest = try Guest(scripts: [
            ("Xfce", "echo '==> Installing Xfce'\necho one >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
            ("Docker", "#!/bin/sh\necho '==> Installing Docker'\necho two >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
            ("", "echo three >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
        ], settings: "name=Xfce, Docker, Notes\nrestart=yes\nuser=saeed\n")
        #expect(try guest.run() == 0)
        #expect(guest.text(guest.state.appending(path: "order")) == "one\ntwo\nthree\n")
        // What is said at the end is said of all of them.
        #expect(guest.status == "state=finished\nname=Xfce, Docker, Notes\n")
        #expect(guest.done == ["1", "2", "3"])
        // Each says whose turn it is, and one without a name goes by its number.
        let log = guest.text(guest.log)
        #expect(log.contains("Xfce (1 of 3), attempt 1 ====\n==> Installing Xfce\n==== Xfce (1 of 3) ran to its end. ===="))
        #expect(log.contains("Docker (2 of 3), attempt 1 ====\n==> Installing Docker\n"))
        #expect(log.contains("Script 3 (3 of 3), attempt 1 ===="))
        // One restart, once the last of them is through.
        #expect(guest.systemctlCalls == ["enable swiftvm-setup.service", "disable swiftvm-setup.service", "--no-block reboot"])
        #expect(!guest.attemptsLeftBehind)

        // Started by hand when all is done, nothing runs again and nothing is restarted for.
        #expect(try guest.run() == 0)
        #expect(guest.text(guest.state.appending(path: "order")) == "one\ntwo\nthree\n")
        #expect(guest.status == "state=finished\nname=Xfce, Docker, Notes\n")
        #expect(guest.systemctlCalls.filter { $0 == "--no-block reboot" }.count == 1)
    }

    @Test func whenOneFailsThoseAfterItWaitAndTheOnesBeforeItStayDone() throws {
        let guest = try Guest(scripts: [
            ("Xfce", "echo one >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
            ("Docker", "echo '==> Installing Docker'\necho two >> \"$SWIFTVM_SETUP_STATE/order\"\nexit 3\n"),
            ("Notes", "echo three >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
        ], settings: "name=Xfce, Docker, Notes\nrestart=yes\nuser=saeed\n")
        #expect(try guest.run() == 3)
        // The one that failed is the one that is named, with the step it failed at.
        #expect(guest.status == "state=failed\nname=Docker (2 of 3)\n")
        #expect(guest.step == "Installing Docker\n")
        #expect(guest.text(guest.state.appending(path: "order")) == "one\ntwo\n")
        #expect(guest.done == ["1"])
        // No restart into a setup that isn't through.
        #expect(!guest.systemctlCalls.contains("--no-block reboot"))

        // Run again once it is put right: what was done isn't done a second time, and the rest follows.
        // What failed may have left the package manager in the middle of its work, which is seen to first.
        try Data("echo two again >> \"$SWIFTVM_SETUP_STATE/order\"\n".utf8).write(to: guest.script(2))
        try guest.addTool("dpkg")
        #expect(try guest.run() == 0)
        #expect(guest.systemctlCalls.filter { $0.hasPrefix("dpkg") } == ["dpkg --force-confdef --force-confold --configure -a"])
        #expect(guest.text(guest.state.appending(path: "order")) == "one\ntwo\ntwo again\nthree\n")
        #expect(guest.status == "state=finished\nname=Xfce, Docker, Notes\n")
        #expect(guest.done == ["1", "2", "3"])
        #expect(guest.systemctlCalls.last == "--no-block reboot")
    }

    @Test func aScriptThatIsCutShortIsTheOneThatIsRunAgain() throws {
        let guest = try Guest(scripts: [
            ("Xfce", "echo one >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
            ("Docker", "echo two >> \"$SWIFTVM_SETUP_STATE/order\"\n"),
        ], settings: "name=Xfce, Docker\nrestart=no\nuser=saeed\n")
        // The machine went down while the second one ran: the first is on record, and so is one start of the second.
        try FileManager.default.createDirectory(at: guest.state.appending(path: "done"), withIntermediateDirectories: true)
        try Data().write(to: guest.state.appending(path: "done/1"))
        try Data("1\n".utf8).write(to: guest.state.appending(path: "attempts"))
        try Data().write(to: guest.state.appending(path: "begun"))
        try Data("state=running\nname=Docker (2 of 2)\n".utf8).write(to: guest.state.appending(path: "status"))
        try guest.addTool("dpkg")
        #expect(try guest.run() == 0)
        #expect(guest.text(guest.state.appending(path: "order")) == "two\n")
        #expect(guest.text(guest.log).contains("Docker (2 of 2), attempt 2 ===="))
        #expect(guest.status == "state=finished\nname=Xfce, Docker\n")
        // The package manager may have been cut short with it, and is seen to before the script runs again.
        #expect(guest.systemctlCalls == [
            "enable swiftvm-setup.service", "dpkg --force-confdef --force-confold --configure -a", "disable swiftvm-setup.service",
        ])

        // Each script has its own count of starts: the first one's don't leave the second with fewer.
        let other = try Guest(scripts: [
            ("Xfce", "echo one\n"), ("Docker", "echo two\n"),
        ], settings: "name=Xfce, Docker\nrestart=no\nuser=saeed\n")
        try FileManager.default.createDirectory(at: other.state, withIntermediateDirectories: true)
        try Data("2\n".utf8).write(to: other.state.appending(path: "attempts"))
        try Data().write(to: other.state.appending(path: "begun"))
        try other.addTool("dpkg")
        #expect(try other.run() == 0)
        #expect(other.text(other.log).contains("Xfce (1 of 2), attempt 3 ===="))
        #expect(other.text(other.log).contains("Docker (2 of 2), attempt 1 ===="))
        // Only before the one that was cut short: a script on its first start finds things as they are.
        #expect(other.systemctlCalls.filter { $0.hasPrefix("dpkg") }.count == 1)

        // One that never comes to its end is given up on by its name, and those after it with it.
        let stuck = try Guest(scripts: [
            ("Xfce", "echo one\n"), ("Docker", "echo two\n"), ("Notes", "echo three\n"),
        ], settings: "name=Xfce, Docker, Notes\nrestart=no\nuser=saeed\n")
        try FileManager.default.createDirectory(at: stuck.state.appending(path: "done"), withIntermediateDirectories: true)
        try Data().write(to: stuck.state.appending(path: "done/1"))
        try Data("3\n".utf8).write(to: stuck.state.appending(path: "attempts"))
        #expect(try stuck.run() == 1)
        #expect(stuck.status == "state=failed\nname=Docker (2 of 3)\n")
        #expect(stuck.done == ["1"])
        #expect(!stuck.text(stuck.log).contains("three"))
    }

    @Test func whatItIsToldIsNeverRun() throws {
        let guest = try Guest(script: "echo \"for $SWIFTVM_USER\"\n", settings: "name=$(touch pwned) `touch pwned`\nrestart=yes; touch pwned\nuser=a=b c\n")
        #expect(try guest.run() == 0)
        #expect(guest.status == "state=finished\nname=$(touch pwned) `touch pwned`\n")
        // The script's own name went through the same hands while it ran.
        #expect(guest.text(guest.log).contains("$(touch pwned) `touch pwned`, attempt 1 ===="))
        #expect(guest.text(guest.log).contains("for a=b c\n"))
        // "yes; touch pwned" isn't yes.
        #expect(guest.systemctlCalls == ["enable swiftvm-setup.service", "disable swiftvm-setup.service"])
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: guest.root.path)
        #expect(!leftovers.contains { $0.hasSuffix("pwned") })
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/pwned"))
    }

    @Test func theUnitAndTheRunnerAgreeOnTheirNames() throws {
        let unit = try LinuxGuestAgent.resource("swiftvm-setup.service")
        #expect(unit.contains("ExecStart=/bin/sh \(LinuxGuestSetup.runnerPath)\n"))
        #expect(unit.contains("ConditionPathExists=\(LinuxGuestSetup.scriptPath(number: 1))\n"))
        #expect(LinuxGuestSetup.scriptPath(number: 2) == LinuxGuestSetup.directory + "/scripts/2")
        // Wanted by the target that the first-boot setup's last step belongs to, not by the one that
        // step waits for.
        #expect(unit.contains("\nWantedBy=cloud-init.target\n"))
        #expect(unit.contains("\nAfter=cloud-final.service"))
        let runner = try LinuxGuestAgent.resource("setup-run.sh")
        #expect(runner.contains("unit=\(LinuxGuestSetup.unitName)\n"))
        #expect(runner.contains("home=${SWIFTVM_SETUP_HOME:-\(LinuxGuestSetup.directory)}\n"))
        #expect(runner.contains("log=${SWIFTVM_SETUP_LOG:-\(GuestIntegration.setupLogPath)}\n"))
        #expect(runner.contains(GuestIntegration.setupRetryCommand))
        // The agent looks for the runner's notes where the runner leaves them.
        let agent = try LinuxGuestAgent.resource("swiftvm-agent.py")
        #expect(agent.contains("\nSETUP_DIRECTORY = \"/var/lib/swiftvm/setup\"\n"))
        #expect(runner.contains("state=${SWIFTVM_SETUP_STATE:-/var/lib/swiftvm/setup}\n"))
        try ProcessRunner.run("/bin/sh", ["-n"], input: Data(runner.utf8))
    }
}
