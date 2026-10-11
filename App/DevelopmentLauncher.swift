import Darwin
import Foundation

/// `swift run SwiftVM` builds the app's program and runs it as it is, outside of an app. Like that it
/// would have no name of its own to macOS, no right to run virtual machines, and the data directory of
/// the app people use. So the bare program never starts up as the app: it hands over to
/// `scripts/run-dev.sh`, which wraps it into the development copy, signs that and opens it.
enum DevelopmentLauncher {
    static func handOverUnlessInAnApp() {
        guard Bundle.main.bundleURL.pathExtension != "app" else { return }
        #if DEBUG
        // This file is in App/, one folder below the scripts' parent.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = repository.appending(path: "scripts/run-dev.sh").path
        guard FileManager.default.isReadableFile(atPath: script),
              let products = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path else {
            stop("SwiftVM was started outside of an app, and \(script), which makes the development copy, isn't there.")
        }
        let command = ["/bin/zsh", script, "--products", products] + CommandLine.arguments.dropFirst()
        var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        arguments.append(nil)
        execv(command[0], arguments)
        stop("Couldn't run \(script): \(String(cString: strerror(errno)))")
        #else
        stop("SwiftVM runs from its app. scripts/build.sh builds it; `swift run SwiftVM` opens a development copy.")
        #endif
    }

    private static func stop(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
