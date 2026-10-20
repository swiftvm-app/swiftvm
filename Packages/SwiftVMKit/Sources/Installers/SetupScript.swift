import Foundation
import GuestChannel
import VMCore

/// A script that sets a new Linux machine up on its first start: installs a desktop, say.
///
/// A setup script is one file. It says what it is in the comments it starts with, one `# key: value`
/// to a line, and the rest is the program, in whatever language its first line names:
///
///     #!/bin/sh
///     # name: KDE Plasma
///     # summary: The KDE Plasma desktop
///     # category: desktop
///     # systems: ubuntu debian
///     # memory: 4
///     # disk: 24
///     # restart: yes
///
///     echo "==> Installing KDE Plasma"
///     apt-get install -y kde-plasma-desktop
///
/// Keys this build doesn't know are passed over, so that a script written for a later one still runs
/// here. A file without a header is a script all the same, and goes by its file name.
public struct SetupScript: Sendable, Hashable, Identifiable {
    public enum ScriptError: Error, LocalizedError, Equatable {
        case notAFile(file: String)
        case notText(file: String)
        case empty(file: String)
        case tooLarge(file: String)
        case badValue(key: String, value: String, expected: String)
        case badFileName(String)
        case nameTaken(String)
        case nameOfTemplate(String)
        case unknown(name: String, system: String, available: [String])

        public var errorDescription: String? {
            switch self {
            case .badFileName(let name):
                name.isEmpty
                    ? "Give the script a name. It is saved as a file with that name."
                    : "“\(name)” can't be the name of the script's file. Keep it under \(SetupScript.maximumNameLength) characters, leave out / and :, and don't start it with a dot or #, or end it with ~."
            case .nameTaken(let name):
                "Your folder has a script called “\(name)” already."
            case .nameOfTemplate(let name):
                "SwiftVM brings a script called “\(name)”. Give yours another name."
            case .unknown(let name, let system, let available):
                "No setup script is called “\(name)”. Available for \(system): \(available.joined(separator: ", ")). For a file, give its path, as in ./\(name)."
            case .notAFile(let file):
                "“\(file)” isn't a file."
            case .notText(let file):
                "“\(file)” isn't a script: it isn't text."
            case .empty(let file):
                "“\(file)” is empty."
            case .tooLarge(let file):
                "“\(file)” is larger than a setup script may be (\(SetupScript.maximumSize / 1024) KB)."
            case .badValue(let key, let value, let expected):
                "The script's header says “\(key): \(value)”, where \(expected) belongs."
            }
        }
    }

    /// Where a script comes from.
    public enum Origin: Sendable, Hashable {
        /// One of the scripts the app brings.
        case builtIn
        /// A file in the user's folder of scripts.
        case library
        /// A file that was picked for one machine.
        case file
    }

    /// What the script is asked for by: the name of its file, without what follows the last dot.
    public var id: String
    /// What the script sets up, as it is shown: `KDE Plasma`.
    public var name: String
    public var summary: String?
    /// The kind of thing it sets up, in lower case: the heading it is listed under.
    /// ``desktopCategory`` is the one that means something to the app.
    public var category: String?
    /// The distributions it is written for, each by its family (`ubuntu`) or by its place in the catalog
    /// (`ubuntu-26.04`). Empty means any.
    public var systems: [String]
    /// The least memory and disk a machine needs for what the script installs, in GB.
    public var minimumMemoryGigabytes: Int?
    public var minimumDiskGigabytes: Int?
    /// Restart the guest once the script has run to its end without an error.
    public var restartsWhenDone: Bool
    /// Prefer the Mac's GPU for a new machine unless the user chose a backend themselves.
    public var recommendsGraphicsAcceleration = false
    /// The whole file, as it runs in the guest.
    public var source: String
    public var origin = Origin.file

    /// No script is larger than this, in bytes of UTF-8. It travels in the machine's first-boot data.
    public static let maximumSize = 256 * 1024
    /// The longest a name is shown at. What is longer is cut.
    public static let maximumNameLength = 60
    /// No machine is set up with more scripts than this. All of them travel in its first-boot data.
    public static let maximumPerMachine = 8
    public static let maximumCategoryLength = 30
    static let maximumSystems = 16
    public static let desktopCategory = "desktop"

    /// Reads a script from its text.
    ///
    /// - Parameter fileName: The name of the file the text is from. It gives the script its ``id``, and
    ///   its name if the header has none.
    public init(source text: String, fileName: String) throws {
        // A file written on Windows would ask Linux for an interpreter called "sh\r".
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        // What is said about a file is printed in a terminal, and the name of a file can hold anything.
        let shownName = Self.shown(fileName)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScriptError.empty(file: shownName)
        }
        guard source.utf8.count <= Self.maximumSize else { throw ScriptError.tooLarge(file: shownName) }
        // Nothing a text editor shows would have one of these in it.
        guard !source.unicodeScalars.contains(where: { $0.value == 0 }) else { throw ScriptError.notText(file: shownName) }

        let baseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        // The name of a file can hold anything. This one is printed in a terminal.
        self.id = Self.cleaned(baseName, limit: Self.maximumNameLength).lowercased()
        self.name = Self.cleaned(baseName, limit: Self.maximumNameLength)
        self.systems = []
        self.restartsWhenDone = false
        self.source = source

        for (key, value) in Self.header(of: source) {
            switch key {
            case "name":
                let cleaned = Self.cleaned(value, limit: Self.maximumNameLength)
                if !cleaned.isEmpty { name = cleaned }
            case "summary":
                let cleaned = Self.cleaned(value, limit: 200)
                summary = cleaned.isEmpty ? nil : cleaned
            case "category":
                let cleaned = Self.cleaned(value, limit: Self.maximumCategoryLength).lowercased()
                category = cleaned.isEmpty ? nil : cleaned
            case "systems":
                // The names of a few systems. Like everything else in a header, they are shown as they are.
                systems = Self.cleaned(value, limit: 200).lowercased()
                    .split(whereSeparator: { $0 == "," || $0.isWhitespace }).prefix(Self.maximumSystems).map(String.init)
            case "memory":
                minimumMemoryGigabytes = try Self.gigabytes(value, key: key)
            case "disk":
                minimumDiskGigabytes = try Self.gigabytes(value, key: key)
            case "graphics":
                switch value.lowercased() {
                case "recommended": recommendsGraphicsAcceleration = true
                case "optional": recommendsGraphicsAcceleration = false
                default: throw ScriptError.badValue(key: key, value: Self.cleaned(value, limit: 40), expected: "recommended or optional")
                }
            case "restart":
                switch value.lowercased() {
                case "yes", "true", "on": restartsWhenDone = true
                case "no", "false", "off": restartsWhenDone = false
                default: throw ScriptError.badValue(key: key, value: Self.cleaned(value, limit: 40), expected: "yes or no")
                }
            default:
                break
            }
        }
    }

    /// Reads the script in the file at `url`.
    public init(contentsOf url: URL) throws {
        let fileName = url.lastPathComponent
        let shownName = Self.shown(fileName)
        // The file a link leads to is the one that is read, so it is the one to look at.
        let file = url.resolvingSymlinksInPath()
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        // A pipe or a device has no end to read up to, and reading one could wait for good.
        guard values.isRegularFile == true else { throw ScriptError.notAFile(file: shownName) }
        // Before any of it is read: a disk image picked by mistake isn't worth taking in to turn down.
        guard let size = values.fileSize, size <= Self.maximumSize else { throw ScriptError.tooLarge(file: shownName) }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else {
            throw ScriptError.notText(file: shownName)
        }
        try self.init(source: text, fileName: fileName)
    }

    public var isDesktop: Bool { category == Self.desktopCategory }

    /// Whether the account needs a password for what the script sets up. A desktop asks for it at its
    /// login screen, where an SSH key is of no use.
    public var requiresPassword: Bool { isDesktop }

    /// Whether the script is written for `distribution`.
    public func supports(_ distribution: LinuxDistribution) -> Bool {
        systems.isEmpty || systems.contains(distribution.distribution.lowercased()) || systems.contains(distribution.id.lowercased())
    }

    /// Whether the script is one to show for what was typed into a filter: every word of `filter` is
    /// part of its name, its summary, the heading it is listed under, or the name it is added by.
    /// Capitals and accents make no difference, and an empty filter shows everything.
    public func matches(filter: String) -> Bool {
        let texts = [name, summary ?? "", SetupScriptCatalog.heading(ofCategory: category), id]
        return filter.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            texts.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// What a machine with this much memory and disk, in bytes, lacks for what the script installs, or
    /// `nil` if it has enough.
    public func shortfall(memorySize: UInt64, diskCapacity: UInt64) -> String? {
        if let minimum = minimumMemoryGigabytes, memorySize < UInt64(minimum) * HostResources.gibibyte {
            return "\(name) needs at least \(minimum) GB of memory."
        }
        if let minimum = minimumDiskGigabytes, diskCapacity < UInt64(minimum) * HostResources.gibibyte {
            return "\(name) needs a disk of at least \(minimum) GB."
        }
        return nil
    }

    /// Why a machine for `distribution` with this much memory and disk, in bytes, can't be set up with
    /// the script, or `nil` if it can.
    ///
    /// - Parameter maximumMemorySize: The most memory this Mac gives a guest.
    public func problem(
        for distribution: LinuxDistribution, memorySize: UInt64, diskCapacity: UInt64,
        maximumMemorySize: UInt64 = HostResources.maximumGuestMemorySize
    ) -> String? {
        guard supports(distribution) else {
            return "\(name) isn't written for \(distribution.name). It is for: \(systems.joined(separator: ", "))."
        }
        // What no machine on this Mac can have isn't something to ask the user to raise.
        if let minimum = minimumMemoryGigabytes, UInt64(minimum) * HostResources.gibibyte > maximumMemorySize {
            return "\(name) needs at least \(minimum) GB of memory, which is more than this Mac can give a virtual machine."
        }
        if let minimum = minimumDiskGigabytes, minimum > HostResources.maximumDiskGigabytes {
            return "\(name) asks for a disk of \(minimum) GB, which is more than a disk can have (\(HostResources.maximumDiskGigabytes) GB)."
        }
        return shortfall(memorySize: memorySize, diskCapacity: diskCapacity)
    }

    // MARK: Header

    /// The `# key: value` lines the file starts with, in their order, with the keys in lower case.
    ///
    /// The header is the run of comment lines at the top, after the line that names the interpreter if
    /// there is one. It ends at the first line that isn't a comment.
    static func header(of source: String) -> [(key: String, value: String)] {
        var entries: [(key: String, value: String)] = []
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.first?.hasPrefix("#!") == true {
            lines = lines.dropFirst()
        }
        for line in lines {
            guard line.hasPrefix("#") else { break }
            let comment = line.drop { $0 == "#" }
            guard let colon = comment.firstIndex(of: ":") else { continue }
            let key = comment[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // A sentence with a colon in it is a comment, not a key.
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { continue }
            entries.append((key, comment[comment.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return entries
    }

    private static func gigabytes(_ value: String, key: String) throws -> Int {
        guard let number = Int(value), (1...4096).contains(number) else {
            throw ScriptError.badValue(key: key, value: cleaned(value, limit: 40), expected: "a number of GB")
        }
        return number
    }

    /// `text` as one line that can be shown: without control characters, and no longer than `limit`.
    static func cleaned(_ text: String, limit: Int) -> String {
        ShownText.line(text, limit: limit)
    }

    /// The name of a file, as it is shown.
    static func shown(_ fileName: String) -> String {
        cleaned(fileName, limit: 100)
    }
}

/// What the scripts of one machine ask of it together. They run in their order.
public extension Collection where Element == SetupScript {
    /// What they set up, as one line: `Xfce, Docker`.
    var setupName: String {
        map(\.name).joined(separator: ", ")
    }

    /// Whether the account needs a password for any of them.
    var requiresPassword: Bool {
        contains(where: \.requiresPassword)
    }

    var recommendsGraphicsAcceleration: Bool {
        contains(where: \.recommendsGraphicsAcceleration)
    }

    /// Whether the guest restarts once all of them have run. It does if any of them asks for it, and
    /// only then: one in the middle doesn't cut the others off.
    var restartsWhenDone: Bool {
        contains(where: \.restartsWhenDone)
    }

    /// The least memory and disk a machine needs for all of them, in GB: what the most demanding asks.
    var minimumMemoryGigabytes: Int? {
        compactMap(\.minimumMemoryGigabytes).max()
    }

    var minimumDiskGigabytes: Int? {
        compactMap(\.minimumDiskGigabytes).max()
    }

    /// Why a machine for `distribution` with this much memory and disk, in bytes, can't be set up with
    /// these scripts, or `nil` if it can.
    func problem(
        for distribution: LinuxDistribution, memorySize: UInt64, diskCapacity: UInt64,
        maximumMemorySize: UInt64 = HostResources.maximumGuestMemorySize
    ) -> String? {
        if count > SetupScript.maximumPerMachine {
            return "A machine is set up with \(SetupScript.maximumPerMachine) scripts at most."
        }
        if distribution.preparedImage(for: Array(self)) != nil, filter(\.isDesktop).count > 1 {
            return "A ready-made desktop image can't be combined with another desktop. Choose one desktop setup."
        }
        var seen: Set<String> = []
        for script in self where !seen.insert(script.source).inserted {
            return "\(script.name) is listed twice."
        }
        return lazy.compactMap {
            $0.problem(for: distribution, memorySize: memorySize, diskCapacity: diskCapacity, maximumMemorySize: maximumMemorySize)
        }.first
    }
}

/// Every setup script there is to pick from.
///
/// This is the one place scripts come from: the app itself, and the folder the user keeps their own
/// in. A list fetched from elsewhere would join them here.
public enum SetupScriptCatalog {
    /// A file in a folder of scripts that can't be one, and why.
    public struct Skipped: Sendable, Hashable {
        public var fileName: String
        public var reason: String
    }

    /// Scripts of one kind, under the heading they are listed by.
    public struct Group: Sendable, Hashable, Identifiable {
        public var title: String
        public var scripts: [SetupScript]

        public var id: String { title }
    }

    /// The files in `Resources/SetupScripts`, in the order they are offered: the desktops, and what
    /// else a new machine is often wanted with. The documentation shows the short ones in full.
    static let builtInFileNames = [
        "gnome.sh", "kde-plasma.sh", "xfce.sh", "cinnamon.sh", "hyprland.sh", "omarchy.sh", "docker.sh", "web-server.sh", "updates.sh",
    ]

    /// The scripts bundled with the app.
    public static let builtIn: [SetupScript] = builtInFileNames.compactMap { fileName in
        guard var script = (try? LinuxGuestAgent.resource(fileName)).flatMap({ try? SetupScript(source: $0, fileName: fileName) }) else {
            return nil
        }
        script.origin = .builtIn
        return script
    }

    /// The folder a user keeps scripts of their own in: `~/.config/swiftvm/setup-scripts`. The app and
    /// its development copy read the same one, as a script is the user's and not a machine's.
    public static var userDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/swiftvm/setup-scripts", directoryHint: .isDirectory)
    }

    /// No more files than this are read from a folder, which is read whenever scripts are listed.
    static let maximumFolderFiles = 200

    /// Makes the user's folder if it isn't there, and returns it.
    @discardableResult
    public static func makeUserDirectory(at directory: URL = userDirectory) throws -> URL {
        // For the user alone: a script may hold what isn't everyone's to read.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// What a new script starts from when the user writes one in the app.
    ///
    /// It has no `name` in its header: the name it is saved under is the one it goes by, until the user
    /// writes another there.
    public static let newScriptTemplate = """
        #!/bin/sh
        # summary: What it sets up, in one line
        # systems: ubuntu debian

        set -eu

        echo "==> Installing"
        apt-get update
        apt-get install -y htop

        """

    /// Saves a script the user wrote as a file in their folder, and returns it as it is listed from
    /// then on. A file that is there already is never written over.
    ///
    /// - Parameter fileName: The name for the file, which is what the script is asked for by. It gets
    ///   `.sh` for an ending if it has none.
    public static func save(source: String, fileName: String, in directory: URL = userDirectory) throws -> SetupScript {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name is one file in the folder: nothing that leads out of it, is hidden in it, or can't be shown.
        guard !name.isEmpty, !name.hasPrefix("."), !name.hasPrefix("#"), !name.hasSuffix("~"), !name.contains(where: { $0 == "/" || $0 == ":" }),
              name == shown(name), name.count <= SetupScript.maximumNameLength
        else {
            throw SetupScript.ScriptError.badFileName(name)
        }
        // An ending is a few letters, as in `.sh` and `.py`. What follows the dot in `nginx-1.24` is part
        // of the name, and would be lost as an ending.
        let ending = (name as NSString).pathExtension
        if ending.isEmpty || ending.count > 5 || !ending.allSatisfy({ $0.isASCII && $0.isLetter }) {
            name += ".sh"
        }
        // Read as it would be once it is in the folder, before anything is written.
        var script = try SetupScript(source: source, fileName: name)
        script.origin = .library
        // A file in the folder with the name of one of the app's takes its place. That is for someone
        // who puts it there on purpose, not for a name that was typed without knowing it is taken.
        guard !builtIn.contains(where: { $0.id == script.id }) else {
            throw SetupScript.ScriptError.nameOfTemplate(script.id)
        }
        let file = directory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: file.path), !userScripts(in: directory).scripts.contains(where: { $0.id == script.id }) else {
            throw SetupScript.ScriptError.nameTaken(script.id)
        }
        try makeUserDirectory(at: directory)
        // Made anew or not at all: a file that turned up in the meantime is left as it is.
        try Data(script.source.utf8).write(to: file, options: .withoutOverwriting)
        return script
    }

    /// The scripts in a folder, by name, and the files in it that can't be scripts.
    ///
    /// Every file directly in the folder is a script, whatever its name ends in. Hidden files, what an
    /// editor keeps next to a file it has open (`name~`, `#name#`) and folders are passed over. A folder
    /// that isn't there holds nothing.
    public static func userScripts(in directory: URL = userDirectory) -> (scripts: [SetupScript], skipped: [Skipped]) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return ([], [])
        } catch {
            return ([], [Skipped(fileName: shown(directory.lastPathComponent), reason: error.localizedDescription)])
        }
        let candidates = files
            .filter { !$0.lastPathComponent.hasSuffix("~") && !$0.lastPathComponent.hasPrefix("#") }
            .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var scripts: [SetupScript] = []
        var skipped: [Skipped] = []
        for file in candidates.prefix(maximumFolderFiles) {
            let fileName = shown(file.lastPathComponent)
            do {
                var script = try SetupScript(contentsOf: file)
                script.origin = .library
                if script.id.isEmpty {
                    skipped.append(Skipped(fileName: fileName, reason: "Its name has nothing in it to ask for it by."))
                } else if scripts.contains(where: { $0.id == script.id }) {
                    // `docker.sh` next to `docker.py`: one name can't ask for both.
                    skipped.append(Skipped(fileName: fileName, reason: "Another script in the folder is called “\(script.id)” too."))
                } else {
                    scripts.append(script)
                }
            } catch {
                skipped.append(Skipped(fileName: fileName, reason: error.localizedDescription))
            }
        }
        if candidates.count > maximumFolderFiles {
            skipped.append(Skipped(
                fileName: shown(directory.lastPathComponent),
                reason: "The folder holds more than \(maximumFolderFiles) files. The rest aren't read."
            ))
        }
        scripts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (scripts, skipped)
    }

    /// Every script: the app's and then the user's, or only those written for `distribution`.
    ///
    /// A script of the user's takes the place of the app's that goes by the same name. That is how one
    /// of the app's is changed: copy it into the folder and edit it.
    public static func all(for distribution: LinuxDistribution? = nil, in directory: URL = userDirectory) -> [SetupScript] {
        listing(in: directory).scripts.filter { script in distribution.map(script.supports) ?? true }
    }

    /// Every script, as ``all(for:in:)`` has them, and the files in the folder that can't be scripts.
    /// The folder is read once.
    public static func listing(in directory: URL = userDirectory) -> (scripts: [SetupScript], skipped: [Skipped]) {
        let own = userScripts(in: directory)
        return (builtIn.filter { script in !own.scripts.contains { $0.id == script.id } } + own.scripts, own.skipped)
    }

    /// The script that is asked for by `id`, whatever its case.
    public static func script(withID id: String, in directory: URL = userDirectory) -> SetupScript? {
        all(in: directory).first { $0.id == id.lowercased() }
    }

    /// The scripts that are asked for by `references`, in that order. Each is a name from the catalog, or
    /// the path of a file from the root: what starts with a `/`.
    ///
    /// - Parameter distribution: The system they are wanted for, to say what there is for it when a name
    ///   isn't known. Whether each fits that system is for ``Swift/Collection/problem(for:memorySize:diskCapacity:maximumMemorySize:)``.
    public static func scripts(
        for references: [String], distribution: LinuxDistribution, in directory: URL = userDirectory
    ) throws -> [SetupScript] {
        // Read once: the folder may change between one script and the next.
        let catalog = all(in: directory)
        return try references.map { reference in
            if reference.hasPrefix("/") {
                return try SetupScript(contentsOf: URL(fileURLWithPath: reference))
            }
            guard let found = catalog.first(where: { $0.id == reference.lowercased() }) else {
                throw SetupScript.ScriptError.unknown(
                    name: SetupScript.cleaned(reference, limit: SetupScript.maximumNameLength), system: distribution.name,
                    available: catalog.filter { $0.supports(distribution) }.map(\.id)
                )
            }
            return found
        }
    }

    /// `scripts` by their kind, for a list with headings: the desktops first, then the other kinds by
    /// name, and last what says nothing about its kind.
    ///
    /// They are put together by heading, so that no heading comes twice: `desktops` reads the same as
    /// `desktop`, and `other` the same as saying nothing.
    public static func groups(of scripts: [SetupScript]) -> [Group] {
        var titles: [String] = []
        var byTitle: [String: [SetupScript]] = [:]
        for script in scripts {
            let title = heading(ofCategory: script.category)
            if byTitle[title] == nil {
                titles.append(title)
            }
            byTitle[title, default: []].append(script)
        }
        // Scripts that are all of no kind need no heading that sets them apart.
        if titles == [otherHeading] {
            return [Group(title: "Scripts", scripts: scripts)]
        }
        func rank(_ title: String) -> Int {
            title == desktopsHeading ? 0 : title == otherHeading ? 2 : 1
        }
        return titles
            .sorted { (rank($0), $0) < (rank($1), $1) }
            .map { Group(title: $0, scripts: byTitle[$0] ?? []) }
    }

    /// The list of `scripts` by kind, narrowed to what ``SetupScript/matches(filter:)`` what was typed.
    ///
    /// A script keeps the heading it has in the whole list, so that typing doesn't move it, and a
    /// heading with nothing left under it is left out.
    public static func groups(of scripts: [SetupScript], matching filter: String) -> [Group] {
        groups(of: scripts).compactMap { group in
            let matching = group.scripts.filter { $0.matches(filter: filter) }
            return matching.isEmpty ? nil : Group(title: group.title, scripts: matching)
        }
    }

    private static let desktopsHeading = "Desktops"
    private static let otherHeading = "Other"

    /// The heading for a kind of script: `Desktops` for `desktop`, and otherwise the kind as it is
    /// written, with a capital.
    static func heading(ofCategory category: String?) -> String {
        guard let category, !category.isEmpty else { return otherHeading }
        if category == SetupScript.desktopCategory {
            return desktopsHeading
        }
        return category.prefix(1).uppercased() + category.dropFirst()
    }

    private static func shown(_ fileName: String) -> String {
        SetupScript.shown(fileName)
    }
}
