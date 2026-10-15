import DiskTools
import Foundation
import VMCore

/// What Windows Setup is told so that nobody has to sit through it: an answer file that installs
/// Windows Pro on the machine's disk, creates the account and skips every question, and SwiftVM's own
/// setup, which installs the drivers and the guest agent. Both go on the machine's setup disc.
///
/// The edition is Pro because it can be reached by Remote Desktop, which a Windows app shown in a window
/// of its own on the Mac would come through.
public struct WindowsSetup: Sendable, Hashable {
    /// The name the computer has on the network: 15 characters at most.
    public var computerName: String
    public var userName: String
    public var fullName: String?
    public var password: String
    /// The language of the installer, such as `en-US`, which Windows Setup is told to keep.
    public var language: String
    /// Public keys that may sign in over SSH, once Windows has set SSH up.
    public var authorizedKeys: [String]

    public init(computerName: String, userName: String, fullName: String? = nil, password: String, language: String, authorizedKeys: [String] = []) {
        self.computerName = computerName
        self.userName = userName
        self.fullName = fullName
        self.password = password
        self.language = language
        self.authorizedKeys = authorizedKeys
    }

    /// The volume label of the setup disc.
    public static let volumeName = "SWIFTVMSETUP"

    /// Microsoft's key for installing Windows Pro without activating it: it only says which edition to
    /// install. The disc holds several, and Setup would ask.
    static let proInstallationKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// Writes the setup disc: the answer file at its root, where Windows Setup looks for one, and
    /// SwiftVM's setup in a folder of its own.
    public func writeDisc(to url: URL) throws {
        var files: [String: Data] = ["autounattend.xml": Data(answerFile.utf8)]
        for (name, contents) in try WindowsGuestAgent.setupFiles() {
            files["swiftvm/" + name] = contents
        }
        if !authorizedKeys.isEmpty {
            files["swiftvm/authorized_keys"] = Data(authorizedKeys.map { $0 + "\r\n" }.joined().utf8)
        }
        try ISOImageBuilder.makeISO(volumeName: Self.volumeName, files: files, at: url)
    }

    // MARK: The answer file

    public var answerFile: String {
        let component = { (name: String) in
            "<component name=\"\(name)\" processorArchitecture=\"arm64\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\">"
        }
        let language = Self.xml(self.language)
        let password = Self.encodedPassword(self.password)
        // Windows 11 asks for a TPM, Secure Boot, a processor it knows and more memory than a small
        // machine has. It runs well without them, and is told so before it looks.
        let checks = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
        let skips = checks.enumerated().map { index, check in
            """
                    <RunSynchronousCommand wcm:action="add"><Order>\(index + 1)</Order><Path>reg.exe add HKLM\\SYSTEM\\Setup\\LabConfig /v \(check) /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
            """
        }.joined(separator: "\n")
        // The setup disc's letter isn't known ahead: whichever drive has the runner on it.
        let specialize = "cmd.exe /c \"for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do if exist %d:\\swiftvm\\setup.ps1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File %d:\\swiftvm\\setup.ps1 -Phase specialize\""
        let firstLogon = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\\ProgramData\\SwiftVM\\setup\\setup.ps1 -Phase firstlogon"
        let displayName = Self.xml((fullName?.isEmpty == false ? fullName : nil) ?? userName)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <settings pass="windowsPE">
            \(component("Microsoft-Windows-International-Core-WinPE"))
              <SetupUILanguage><UILanguage>\(language)</UILanguage></SetupUILanguage>
              <InputLocale>\(language)</InputLocale>
              <SystemLocale>\(language)</SystemLocale>
              <UILanguage>\(language)</UILanguage>
              <UserLocale>\(language)</UserLocale>
            </component>
            \(component("Microsoft-Windows-Setup"))
              <RunSynchronous>
        \(skips)
              </RunSynchronous>
              <DiskConfiguration>
                <Disk wcm:action="add">
                  <DiskID>0</DiskID>
                  <WillWipeDisk>true</WillWipeDisk>
                  <CreatePartitions>
                    <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                    <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                  </CreatePartitions>
                  <ModifyPartitions>
                    <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Label>System</Label><Format>FAT32</Format></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
                    <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Label>Windows</Label><Letter>C</Letter><Format>NTFS</Format></ModifyPartition>
                  </ModifyPartitions>
                </Disk>
              </DiskConfiguration>
              <ImageInstall>
                <OSImage>
                  <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                </OSImage>
              </ImageInstall>
              <UserData>
                <ProductKey><Key>\(Self.proInstallationKey)</Key><WillShowUI>OnError</WillShowUI></ProductKey>
                <AcceptEula>true</AcceptEula>
              </UserData>
            </component>
          </settings>
          <settings pass="specialize">
            \(component("Microsoft-Windows-Shell-Setup"))
              <ComputerName>\(Self.xml(computerName))</ComputerName>
            </component>
            \(component("Microsoft-Windows-Deployment"))
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>\(Self.xml(specialize))</Path></RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
          <settings pass="oobeSystem">
            \(component("Microsoft-Windows-International-Core"))
              <InputLocale>\(language)</InputLocale>
              <SystemLocale>\(language)</SystemLocale>
              <UILanguage>\(language)</UILanguage>
              <UserLocale>\(language)</UserLocale>
            </component>
            \(component("Microsoft-Windows-Shell-Setup"))
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <ProtectYourPC>3</ProtectYourPC>
              </OOBE>
              <UserAccounts>
                <LocalAccounts>
                  <LocalAccount wcm:action="add">
                    <Name>\(Self.xml(userName))</Name>
                    <DisplayName>\(displayName)</DisplayName>
                    <Group>Administrators</Group>
                    <Password><Value>\(password)</Value><PlainText>false</PlainText></Password>
                  </LocalAccount>
                </LocalAccounts>
              </UserAccounts>
              <AutoLogon>
                <Enabled>true</Enabled>
                <Username>\(Self.xml(userName))</Username>
                <LogonCount>9999999</LogonCount>
                <Password><Value>\(password)</Value><PlainText>false</PlainText></Password>
              </AutoLogon>
              <FirstLogonCommands>
                <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>\(Self.xml(firstLogon))</CommandLine></SynchronousCommand>
              </FirstLogonCommands>
            </component>
          </settings>
        </unattend>

        """
    }

    /// A password the way an answer file holds one that isn't written out: the password and the word
    /// "Password", in UTF-16, in Base64. It only keeps the password from being read at a glance.
    static func encodedPassword(_ password: String) -> String {
        var bytes = Data()
        for unit in (password + "Password").utf16 {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes.base64EncodedString()
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: Names

    /// Why `userName` can't be the name of a Windows account, or `nil` if it can.
    public static func problem(withUserName userName: String) -> String? {
        guard !userName.isEmpty else { return "Enter an account name." }
        let forbidden = CharacterSet(charactersIn: "\"/\\[]:;|=,+*?<>@%")
        guard userName.unicodeScalars.allSatisfy({ !forbidden.contains($0) && $0.value >= 32 }),
              userName.count <= 20,
              !userName.allSatisfy({ $0 == "." || $0 == " " }),
              !userName.hasSuffix(".")
        else {
            return "Use up to 20 characters, without \" / \\ [ ] : ; | = , + * ? < > @ %, and not ending in a dot."
        }
        if reservedUserNames.contains(userName.lowercased()) {
            return "“\(userName)” is reserved by Windows. Choose another account name."
        }
        return nil
    }

    private static let reservedUserNames: Set<String> = [
        "administrator", "guest", "defaultaccount", "wdagutilityaccount", "system", "network service", "local service",
        "administrators", "users", "everyone",
    ]

    /// Why `password` can't be the account's, or `nil` if it can. Windows takes an empty one, but then
    /// nobody can sign in over the network, which SSH and Remote Desktop are.
    public static func problem(withPassword password: String) -> String? {
        password.isEmpty ? "Enter a password. Windows doesn't let an account without one sign in over SSH or Remote Desktop." : nil
    }

    /// A computer name made of `name`, which may be anything: letters, digits and hyphens, 15 at most,
    /// and not only digits.
    public static func computerName(from name: String) -> String {
        let allowed = name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var result = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        result = String(result.prefix(15)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if result.isEmpty || result.allSatisfy(\.isNumber) {
            result = "WINDOWS-" + String(result.prefix(7))
        }
        return result
    }
}

/// What a Windows installer disc is, read from the disc.
public enum WindowsInstaller {
    public enum InstallerError: Error, LocalizedError, Equatable {
        case notWindows(String)
        case notForArm(String)

        public var errorDescription: String? {
            switch self {
            case .notWindows(let name):
                "“\(name)” isn't a Windows installer."
            case .notForArm(let name):
                "“\(name)” is Windows for Intel and AMD processors. A Mac with Apple silicon runs Windows for Arm: download the Arm64 ISO."
            }
        }
    }

    /// Checks that the disc at `url` installs Windows on Arm, and returns the language it installs, such
    /// as `en-US`.
    ///
    /// Windows' discs keep their files in UDF, with an ISO 9660 part that only holds a note saying so,
    /// and `tar` reads no further than that. macOS reads UDF, so the disc is mounted to look inside:
    /// read-only and out of sight, for a moment.
    public static func inspect(_ url: URL) throws -> String {
        let name = url.lastPathComponent
        let mountPoint = FileManager.default.temporaryDirectory.appending(path: "swiftvm-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        do {
            try ProcessRunner.run("/usr/sbin/diskutil", [
                "image", "attach", "--readOnly", "--mountOptions", "nobrowse", "--mountPoint", mountPoint.path, url.path,
            ])
        } catch {
            throw InstallerError.notWindows(name)
        }
        defer { _ = try? ProcessRunner.run("/usr/sbin/diskutil", ["eject", "force", mountPoint.path]) }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: mountPoint.appending(path: "sources/boot.wim").path) else { throw InstallerError.notWindows(name) }
        guard fileManager.fileExists(atPath: mountPoint.appending(path: "efi/boot/bootaa64.efi").path) else { throw InstallerError.notForArm(name) }
        let languages = (try? String(contentsOf: mountPoint.appending(path: "sources/lang.ini"), encoding: .utf8))
            ?? (try? String(contentsOf: mountPoint.appending(path: "sources/lang.ini"), encoding: .utf16)) ?? ""
        return language(inLanguageList: languages) ?? "en-US"
    }

    /// Whether the disc at `url` looks like one of Microsoft's Windows installers, by its volume label:
    /// such as `CCCOMA_A64FRE_EN-US_DV9`. Quick enough to tell a dropped file by; ``inspect(_:)`` is what
    /// makes sure.
    public static func looksLikeWindows(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // The label is in the primary volume descriptor, in the sixteenth sector of 2 KB.
        guard (try? handle.seek(toOffset: 16 * 2048)) != nil, let descriptor = try? handle.read(upToCount: 72), descriptor.count == 72,
              descriptor[descriptor.startIndex + 1..<descriptor.startIndex + 6] == Data("CD001".utf8)
        else { return false }
        let label = String(decoding: descriptor[(descriptor.startIndex + 40)..<(descriptor.startIndex + 72)], as: UTF8.self)
        return label.uppercased().contains("FRE_")
    }

    /// The first language a disc's `sources/lang.ini` lists as one it shows Setup in.
    static func language(inLanguageList text: String) -> String? {
        var isInList = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isInList = line.lowercased() == "[available ui languages]"
                continue
            }
            guard isInList, let tag = line.split(separator: "=").first?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { continue }
            // `en-us` as Windows writes it, `en-US` as it is meant.
            let parts = tag.split(separator: "-")
            guard let first = parts.first else { continue }
            return ([first.lowercased()] + parts.dropFirst().map { $0.count == 2 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst().lowercased() })
                .joined(separator: "-")
        }
        return nil
    }
}
