import DiskTools
import Foundation
import GuestChannel
import Testing
import VMCore
@testable import Installers

@Suite struct LinuxGuestAgentTests {
    @Test func knowsTheVersionOfTheAgentItCarries() throws {
        #expect(LinuxGuestAgent.version(ofScript: "import os\nAGENT_VERSION = \"2.3\"\nPORT = 717\n") == "2.3")
        #expect(LinuxGuestAgent.version(ofScript: "print('hello')\n") == nil)
    }

    @Test func installsOverSSHAsRoot() {
        let arguments = LinuxGuestAgent.installArguments(alias: "web", configURL: URL(fileURLWithPath: "/tmp/ssh config"))
        #expect(arguments.prefix(2) == ["-F", "/tmp/ssh config"])
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=5"))
        #expect(arguments.suffix(2) == [
            "web",
            "sudo -n sh -c 'umask 077; d=$(mktemp -d /tmp/swiftvm-tools.XXXXXXXX) || exit 1; "
                + "cat > \"$d/install.sh\" && sh \"$d/install.sh\"; code=$?; rm -rf \"$d\"; exit $code'",
        ])
    }

    @Test func tellsTheInstallersOwnNoFromNotGettingIn() throws {
        /// What `ssh` leaves behind when the far end printed `text` and failed.
        func failure(printing text: String) -> ProcessRunner.Failure? {
            do {
                try ProcessRunner.run("/bin/sh", ["-c", "cat >&2; exit 1"], input: Data(text.utf8))
                return nil
            } catch {
                return error as? ProcessRunner.Failure
            }
        }
        // The installer ran and refused: its reason is the answer, and a disc wouldn't change it.
        let noPython = try #require(failure(printing: "swiftvm: the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again\n"))
        #expect(LinuxGuestAgent.installerComplaint(in: noPython) == "the guest agent needs Python 3 at /usr/bin/python3. Install it and run this again")
        let noisy = try #require(failure(printing: "Warning: Permanently added 'web' (ED25519) to the list of known hosts.\nswiftvm: this system doesn't use systemd, which the guest agent needs\n"))
        #expect(LinuxGuestAgent.installerComplaint(in: noisy) == "this system doesn't use systemd, which the guest agent needs")
        // It never ran: there was no way in, and the disc is one.
        for text in ["sudo: a password is required\n", "web: Permission denied (publickey).\n", "", "swiftvm:\n"] {
            let noWayIn = try #require(failure(printing: text))
            #expect(LinuxGuestAgent.installerComplaint(in: noWayIn) == nil)
        }
    }

    /// agent-desktop refuses a full-screen picture under GNOME on X11 and the pointer on Wayland. The
    /// agent stands in for it on exactly those refusals, which come before anything was done, and never
    /// for a ref, an option it doesn't know, or a refusal after which the action may have happened.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func standsInForAgentDesktopOnlyWhereItRefusedBeforeDoingAnything() throws {
        let agent = try #require(LinuxGuestAgent.resourceURL("swiftvm-agent.py"))
        let checks = #"""
        import importlib.util, json, sys
        spec = importlib.util.spec_from_file_location("agent", sys.argv[1])
        agent = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(agent)
        command = agent.desktop_command

        def refusal(name, code, details, delivery="not_delivered"):
            return json.dumps({"version": "2.5", "ok": False, "command": name, "error": {
                "code": code, "message": "-", "details": details, "disposition": {"delivery": delivery, "retry": "safe"}}}).encode()

        click = command(["--headed", "mouse-click", "--xy=10,20.5", "--button", "right", "--count", "2", "--modifiers", "cmd"])
        assert click == {"command": "mouse-click", "point": (10.0, 20.5), "button": "right", "count": 2, "modifiers": ["super"]}, click
        assert command(["--session", "s", "screenshot", "shot.png"]) == {"command": "screenshot", "path": "shot.png"}
        assert command(["mouse-click", "--xy", "1,1", "--modifiers", "command"])["modifiers"] == ["super"]
        # agent-desktop's wheel turns 3 lines down unless told a way to turn.
        assert command(["mouse-wheel", "--x", "5", "--y", "6"])["dy"] == -3.0
        assert command(["mouse-wheel", "--x", "5", "--y", "6", "--dx", "0"])["dy"] == -3.0
        assert command(["mouse-wheel", "--x", "5", "--y", "6", "--dx", "2"])["dy"] == 0.0
        drag = command(["drag", "--from-xy", "1,2", "--to-xy", "3,4"])
        assert (drag["to"], drag["drop_delay"]) == ((3.0, 4.0), 150), drag
        for refused in (
            ["click", "@s1:e1"], ["hover", "@s1:e1"], ["drag", "--from", "@s1:e1", "--to-xy", "3,4"],
            ["screenshot", "--app", "Muxy"], ["screenshot", "--window-id", "7"], ["--trace", "t", "mouse-click", "--xy", "1,1"],
            ["mouse-click", "--xy", "1,1", "--wait-for", "button:OK"], ["mouse-click", "--xy", "nan,1"], ["mouse-click"],
            # What the agent's own pointer can't do as asked keeps agent-desktop's refusal.
            ["mouse-click", "--xy", "1,1", "--count", "²"], ["mouse-click", "--xy", "1,1", "--count", "4"],
            ["mouse-wheel", "--x", "5", "--y", "6", "--dy", "0.4"],
        ):
            assert command(refused) is None, refused
        assert agent.desktop_subcommand(["--trace", "t.jsonl", "screenshot"]) == "screenshot"

        screenshot = command(["screenshot"])
        assert agent.refused_for_the_agent(screenshot, refusal("screenshot", "PLATFORM_NOT_SUPPORTED", {"reason": "compositing"}))
        assert not agent.refused_for_the_agent(screenshot, refusal("screenshot", "TIMEOUT", {"kind": "portal_consent_timeout"}, "delivery_uncertain"))
        assert not agent.refused_for_the_agent(screenshot, refusal("screenshot", "PERM_DENIED", {}))
        wayland = {"cause": "wayland_session", "physical_delivery_started": False}
        assert agent.refused_for_the_agent(click, refusal("mouse-click", "ACTION_NOT_SUPPORTED", wayland))
        assert not agent.refused_for_the_agent(click, refusal("mouse-click", "ACTION_NOT_SUPPORTED", wayland, "delivery_uncertain"))
        assert not agent.refused_for_the_agent(click, refusal("mouse-click", "POLICY_DENIED", {}))
        assert not agent.refused_for_the_agent(click, refusal("drag", "ACTION_NOT_SUPPORTED", wayland))
        assert not agent.refused_for_the_agent(click, b'{"ok": true, "command": "mouse-click"}')

        # agent-desktop's places are in the display's points; the screen may have two pixels to one.
        listed = b'{"ok": true, "data": [{"bounds": {"x": 0, "y": 0, "width": 1920, "height": 1200}, "scale": 2.0}]}'
        display = agent.the_one_display(listed)
        assert display == (0.0, 0.0, 1920.0, 1200.0)
        assert agent.on_screen((960, 600), display, (3840, 2400)) == (1920, 1200)
        assert agent.on_screen((1920, 10), display, (3840, 2400)) is None
        assert agent.same_shape(display, (3840, 2400)) and not agent.same_shape(display, (1024, 768))
        assert agent.the_one_display(listed.replace(b"}]}", b"}, {\"bounds\": {}}]}")) is None
        request = agent.pointer_request(command(["mouse-wheel", "--x", "5", "--y", "6", "--dy", "2"]), display, (1920, 1200))
        assert (request["action"], request["deltaY"]) == ("scroll", -2), request
        print("ok")
        """#
        let result = try ProcessRunner.run("/usr/bin/python3", ["-I", "-c", checks, agent.path])
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
    }

    @Test func makesTheGuestToolsDiscOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-tools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let disc = try LinuxGuestAgent.toolsImage(in: directory)
        #expect(LinuxGuestAgent.isToolsImage(disc.path))
        #expect(!LinuxGuestAgent.isToolsImage("/Users/me/Downloads/ubuntu.iso"))
        #expect(try ISOImageBuilder.text(of: "install.sh", in: disc) == (try LinuxGuestAgent.installer()))
        // A guest finds the disc by its label.
        let label = try ProcessRunner.run("/usr/bin/tar", ["-tvf", disc.path]).standardOutput
        #expect(label.contains("install.sh"))

        // Asked again, the same disc comes back untouched: a guest may have it plugged in.
        let created = try FileManager.default.attributesOfItem(atPath: disc.path)[.modificationDate] as? Date
        #expect(try LinuxGuestAgent.toolsImage(in: directory) == disc)
        #expect(try FileManager.default.attributesOfItem(atPath: disc.path)[.modificationDate] as? Date == created)

        // Discs of other builds go, unless a machine still has one attached.
        let stale = directory.appending(path: "SwiftVM Guest Tools 000000000000.iso")
        let attached = directory.appending(path: "SwiftVM Guest Tools 111111111111.iso")
        let unrelated = directory.appending(path: "notes.txt")
        for url in [stale, attached, unrelated] {
            try Data("x".utf8).write(to: url)
        }
        #expect(try LinuxGuestAgent.toolsImage(in: directory, inUse: [attached.standardizedFileURL.path]) == disc)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: attached.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: disc.path))
    }
}
