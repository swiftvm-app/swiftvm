import Foundation
import Testing
import VMControl

/// Opt-in tests of the real backends. Use a built app and matching guest tools, with an unlocked
/// desktop: SWIFTVM_TEST_CLI=/path/to/swiftvm and SWIFTVM_TEST_MACOS, _LINUX or _WINDOWS naming a VM.
/// The Mac guest needs Swift's command-line tools; Linux needs GTK 3 and its Python bindings.
/// Run Linux once in a Wayland session and once in X11. No machine is created or reconfigured here.
@Suite(.serialized) struct AccessibilityIdentifierGuestTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTVM_TEST_MACOS"] != nil))
    func macOSIdentifierCanBeLookedUpAndClicked() throws {
        try exercise("MACOS", command: ["/usr/bin/swift", "-"], source: Self.macOS)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTVM_TEST_LINUX"] != nil))
    func linuxIdentifierCanBeLookedUpAndClicked() throws {
        try exercise("LINUX", command: ["python3", "-"], source: Self.linux)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTVM_TEST_WINDOWS"] != nil))
    func windowsIdentifierCanBeLookedUpAndClicked() throws {
        try exercise("WINDOWS", command: ["powershell.exe", "-NoProfile", "-NonInteractive", "-Sta"], source: Self.windows)
    }

    private func exercise(_ platform: String, command: [String], source: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let tool = try #require(environment["SWIFTVM_TEST_CLI"], "Point SWIFTVM_TEST_CLI at the built app's swiftvm tool.")
        let machine = try #require(environment["SWIFTVM_TEST_\(platform)"])
        let id = "swiftvm-test-\(UUID().uuidString)"
        let source = source.replacingOccurrences(of: "SAMPLE_ID", with: id)
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: tool)
        let input = Pipe()
        sample.standardInput = input
        let log = FileManager.default.temporaryDirectory.appending(path: "\(id).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        sample.standardOutput = output
        sample.standardError = output
        defer {
            if sample.isRunning { sample.terminate(); sample.waitUntilExit() }
            try? output.close()
            try? FileManager.default.removeItem(at: log)
        }
        if platform == "WINDOWS" {
            let encoded = try #require(source.data(using: .utf16LittleEndian)).base64EncodedString()
            sample.arguments = ["exec", machine, "--timeout", "90", "--"] + command + ["-EncodedCommand", encoded]
        } else {
            sample.arguments = ["exec", machine, "--timeout", "90", "--"] + command
        }
        try sample.run()
        if platform != "WINDOWS" { try input.fileHandleForWriting.write(contentsOf: Data(source.utf8)) }
        try input.fileHandleForWriting.close()

        func control(_ arguments: [String]) throws -> ControlOutcome {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["control", machine] + arguments + ["--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = output
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let outcome = try JSONDecoder().decode(ControlOutcome.self, from: data)
            try #require(process.terminationStatus == 0, "\(outcome.text)\n\((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
            return outcome
        }

        _ = try control(["wait", "--id", id, "--timeout", "45"])
        let look = try control(["look", "--all"])
        let matches = look.results.first?.look?.elements.filter { $0.id == id } ?? []
        #expect(matches.count == 1)
        let element = try #require(matches.first)
        // The visible label is not the identifier. A successful click must reach the sample's handler.
        #expect(element.name != id)
        _ = try control(["click", "#\(id)"])
        _ = try control(["wait", "--id", "clicked-\(id)", "--timeout", "10"])
    }

    private static let macOS = """
        import AppKit
        final class Handler: NSObject {
            @objc func clicked(_ sender: NSButton) {
                sender.setAccessibilityIdentifier("clicked-SAMPLE_ID")
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let handler = Handler()
        let button = NSButton(title: "Sample", target: handler, action: #selector(Handler.clicked(_:)))
        button.frame = NSRect(x: 80, y: 60, width: 140, height: 40)
        button.setAccessibilityIdentifier("SAMPLE_ID")
        window.contentView!.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
        """

    private static let linux = """
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        window = Gtk.Window()
        window.set_default_size(300, 160)
        button = Gtk.Button(label="Sample")
        button.get_accessible().set_accessible_id("SAMPLE_ID")
        button.connect("clicked", lambda sender: sender.get_accessible().set_accessible_id("clicked-SAMPLE_ID"))
        window.add(button)
        window.show_all()
        window.present()
        Gtk.main()
        """

    private static let windows = """
        Add-Type -AssemblyName PresentationFramework
        $owner = New-Object Windows.Window
        $owner.Width = 400
        $owner.Height = 240
        $owner.Show()
        $window = New-Object Windows.Window
        $window.Owner = $owner
        $window.Width = 300
        $window.Height = 160
        $window.WindowStartupLocation = 'CenterScreen'
        $button = New-Object Windows.Controls.Button
        $button.Content = 'Sample'
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, 'SAMPLE_ID')
        $button.Add_Click({ [Windows.Automation.AutomationProperties]::SetAutomationId($button, 'clicked-SAMPLE_ID') })
        $window.Content = $button
        $window.Show()
        # The dialog is also exposed through its owner while another window is in front.
        $front = New-Object Windows.Window
        $front.Width = 150
        $front.Height = 100
        $front.Left = 0
        $front.Top = 0
        $front.Topmost = $true
        $front.Show()
        [Windows.Threading.Dispatcher]::Run()
        """
}
