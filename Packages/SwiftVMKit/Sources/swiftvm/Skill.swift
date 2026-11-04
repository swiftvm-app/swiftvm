import Foundation

/// `swiftvm skill`: what an agent needs to know to use this tool, of the same version as the tool.
enum Skill {
    static let usage = """
    Usage: swiftvm skill                Print the skill, for an agent to read
           swiftvm skill install [--to <folder>]
                                        Install it for agents: into ~/.claude/skills/swiftvm and
                                        ~/.agents/skills/swiftvm, or into the given folder
    """

    static var text: String {
        String(decoding: PackageResources.SKILL_md, as: UTF8.self)
    }

    static func run(_ arguments: [String]) -> Never {
        switch arguments.first {
        case nil:
            print(text, terminator: "")
        case "install":
            var folders: [URL]
            if arguments.count == 3, arguments[1] == "--to" {
                folders = [URL(fileURLWithPath: arguments[2], isDirectory: true)]
            } else {
                guard arguments.count == 1 else { fail(usage) }
                let home = FileManager.default.homeDirectoryForCurrentUser
                folders = [".claude/skills/swiftvm", ".agents/skills/swiftvm"].map { home.appending(path: $0, directoryHint: .isDirectory) }
            }
            for folder in folders {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(text.utf8).write(to: folder.appending(path: "SKILL.md"), options: .atomic)
                } catch {
                    fail("The skill couldn't be installed in \(folder.path): \(error.localizedDescription)")
                }
                print(folder.appending(path: "SKILL.md").path)
            }
        case "--help", "-h", "help":
            print(usage)
        default:
            fail(usage)
        }
        exit(0)
    }
}
