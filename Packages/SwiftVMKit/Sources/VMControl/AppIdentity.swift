import Foundation

/// Which copy of SwiftVM a program is part of: the app people use, or the development copy that
/// `swift run SwiftVM` makes. The two are different apps to macOS and keep their data apart, so that a
/// development copy can run next to the app without ever seeing its machines.
public enum AppIdentity: String, Sendable, CaseIterable {
    case release = "com.swiftvm.app"
    case development = "com.swiftvm.app.dev"

    public var bundleIdentifier: String { rawValue }

    /// What the copy is called in the menu bar and in the Dock, and what it calls itself.
    public var name: String {
        switch self {
        case .release: "SwiftVM"
        case .development: "SwiftVM Dev"
        }
    }

    /// The folder in Application Support where the copy keeps its machines, its network settings and
    /// its control socket.
    public var dataDirectoryName: String {
        switch self {
        case .release: "SwiftVM"
        case .development: "SwiftVM-Dev"
        }
    }

    /// The copy this program is part of. A program that can't tell stops here, with the reason.
    public static let current: AppIdentity = {
        let program = Bundle.main.executableURL
        guard let identity = AppIdentity(ofProgramAt: program) else {
            let app = program.flatMap(appBundle(containing:))?.path ?? "the app it is in"
            FileHandle.standardError.write(Data("SwiftVM can't tell which copy of it this is: the Info.plist of \(app) can't be read.\n".utf8))
            exit(1)
        }
        return identity
    }()

    /// The copy the program at `program` is part of: the one whose app it is inside of. A program
    /// outside an app, such as the `swiftvm` tool built on its own, goes with the app people use, and so
    /// does one inside an app that goes by another name.
    ///
    /// `nil` for a program inside an app that doesn't say what it is. Taking it for the app would hand
    /// it the app's machines, and it may be a development copy.
    public init?(ofProgramAt program: URL?) {
        guard let app = program.flatMap(Self.appBundle(containing:)) else {
            self = .release
            return
        }
        guard let identifier = Self.bundleIdentifier(ofAppAt: app) else { return nil }
        self = AppIdentity(rawValue: identifier) ?? .release
    }

    /// The app that `program` is inside of, be it the app's own program or a tool in its
    /// `Contents/Helpers`. A link to the tool, like the one in `/usr/local/bin`, leads to the tool's app.
    public static func appBundle(containing program: URL) -> URL? {
        var url = program.resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return url
            }
        }
        return nil
    }

    private static func bundleIdentifier(ofAppAt app: URL) -> String? {
        // Read from the file: `Bundle` remembers what it has read for a path, also after the app there
        // was replaced by another.
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return properties["CFBundleIdentifier"] as? String
    }
}
