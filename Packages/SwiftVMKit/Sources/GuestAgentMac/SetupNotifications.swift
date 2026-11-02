import AppKit
import ApplicationServices

/// A one-time cleanup of notices left by setting up a new guest. It runs as the logged-in user,
/// through the already-authorized agent, and never changes notification or background-item settings.
enum SetupNotifications {
    static let mode = "dismiss-setup-notifications"

    static func run() -> Int32 {
        // Cleanup must not put up another permission question of its own.
        guard AXIsProcessTrusted() else { return 1 }
        let deadline = ContinuousClock.now + .seconds(10)
        var dismissed = 0
        repeat {
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui") {
                let root = AXUIElementCreateApplication(application.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.2)
                var remaining = 256
                dismissed += dismiss(in: root, depth: 0, remaining: &remaining, deadline: deadline)
            }
            // Notifications can arrive after the agent connects. Re-read while setup owns the screen;
            // nothing keeps running after this command ends.
            if ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.5) }
        } while ContinuousClock.now < deadline
        print("Dismissed \(dismissed) setup notification(s).")
        return 0
    }

    private static func dismiss(
        in element: AXUIElement, depth: Int, remaining: inout Int, deadline: ContinuousClock.Instant
    ) -> Int {
        guard depth < 16, remaining > 0, ContinuousClock.now < deadline else { return 0 }
        remaining -= 1
        let children: [AXUIElement] = attribute("AXChildren", of: element) ?? []
        let subrole: String? = attribute("AXSubrole", of: element)
        if subrole == "AXNotificationCenterAlert", isSetupNotice(children: children), let action = closeAction(of: element) {
            return AXUIElementPerformAction(element, action as CFString) == .success ? 1 : 0
        }
        var dismissed = 0
        for child in children.prefix(256) {
            dismissed += dismiss(in: child, depth: depth + 1, remaining: &remaining, deadline: deadline)
        }
        return dismissed
    }

    private static func isSetupNotice(children: [AXUIElement]) -> Bool {
        // macOS exposes a card's title and body separately. Never match a containing window or text
        // from a different card. Unrecognized wording, including other languages, is left alone.
        func text(_ identifier: String) -> String? {
            guard let child = children.first(where: { attribute("AXIdentifier", of: $0) as String? == identifier }) else { return nil }
            return attribute("AXValue", of: child)
        }
        guard let title = text("title"), let body = text("body"), body.contains("Login Items") else { return false }
        return ["App Background Activity", "Background Items Added", "Multiple Extensions Added", "Extension Added", "Extensions Added"].contains(title)
    }

    private static func closeAction(of element: AXUIElement) -> String? {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return nil }
        return (names as? [String] ?? []).first { name in
            if name == "AXClose" { return true }
            var description: CFString?
            return AXUIElementCopyActionDescription(element, name as CFString, &description) == .success
                && description as String? == "Close"
        }
    }

    private static func attribute<Value>(_ name: String, of element: AXUIElement) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Value
    }
}
