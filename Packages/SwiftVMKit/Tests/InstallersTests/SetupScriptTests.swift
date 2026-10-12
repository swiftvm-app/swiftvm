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
        for name in ["", "  ", "../escape", "a/b", ".hidden", "#tools", "#tools.sh", " #tools ", "back~", "a:b", "bell\u{7}", String(repeating: "x", count: 61)] {
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

@Suite struct LinuxUserNameTests {
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
    }
}
