import DiskTools
import Foundation
import VMCore

/// First-boot configuration for a Linux cloud image, delivered as a cloud-init NoCloud seed ISO.
public struct CloudInitSeed: Sendable, Hashable {
    public var hostName: String
    /// Changing the instance ID makes cloud-init run its first-boot setup again.
    public var instanceID: String
    public var userName: String
    /// The account's user ID, where it has to be a particular one: that of the Mac's user, for folders
    /// shared over 9p, which shows the Mac's owners as they are. `nil` is the system's choice.
    public var userID: Int?
    public var fullName: String?
    /// Login password; `nil` allows key-based login only.
    public var password: String?
    public var authorizedKeys: [String]
    /// MAC address of the interface to configure with DHCP.
    public var macAddress: String?
    /// IANA time zone identifier for the guest.
    public var timeZone: String?
    /// Mount the virtio-fs share with this tag at ``GuestIntegration/sharedFoldersMountPoint``.
    public var sharedFoldersTag: String?
    /// Register Rosetta (shared with this virtio-fs tag) to run x86-64 binaries.
    public var rosettaTag: String?
    /// Have the kernel write its messages to the serial console too, where `swiftvm console` and the
    /// machine's console log pick them up. Takes effect from the second boot.
    public var kernelMessagesOnSerialConsole: Bool
    /// The script that installs the guest agent (``LinuxGuestAgent/installer()``), to run on the first
    /// boot. `nil` leaves the guest without one.
    public var guestAgentInstaller: String?
    /// Scripts to set the system up with once it is up for the first time, in the order they run: a
    /// desktop, for example.
    public var setupScripts: [SetupScript]

    public init(
        hostName: String,
        instanceID: String = UUID().uuidString.lowercased(),
        userName: String,
        userID: Int? = nil,
        fullName: String? = nil,
        password: String? = nil,
        authorizedKeys: [String] = [],
        macAddress: String? = nil,
        timeZone: String? = TimeZone.current.identifier,
        sharedFoldersTag: String? = GuestIntegration.sharedFoldersTag,
        rosettaTag: String? = nil,
        kernelMessagesOnSerialConsole: Bool = true,
        guestAgentInstaller: String? = try? LinuxGuestAgent.installer(),
        setupScripts: [SetupScript] = []
    ) {
        self.hostName = hostName
        self.instanceID = instanceID
        self.userName = userName
        self.userID = userID
        self.fullName = fullName
        self.password = password
        self.authorizedKeys = authorizedKeys
        self.macAddress = macAddress
        self.timeZone = timeZone
        self.sharedFoldersTag = sharedFoldersTag
        self.rosettaTag = rosettaTag
        self.kernelMessagesOnSerialConsole = kernelMessagesOnSerialConsole
        self.guestAgentInstaller = guestAgentInstaller
        self.setupScripts = setupScripts
    }

    // MARK: Documents

    public var metaData: String {
        Self.metaData(instanceID: instanceID, hostName: hostName)
    }

    static func metaData(instanceID: String, hostName: String) -> String {
        """
        instance-id: \(yaml(instanceID))
        local-hostname: \(yaml(hostName))

        """
    }

    public var userData: String {
        var lines: [String] = ["#cloud-config"]
        lines.append("hostname: \(yaml(hostName))")
        lines.append("manage_etc_hosts: true")
        if let timeZone, !timeZone.isEmpty {
            lines.append("timezone: \(yaml(timeZone))")
        }

        lines.append("users:")
        lines.append("  - name: \(yaml(userName))")
        if let userID {
            lines.append("    uid: \(userID)")
        }
        if let fullName, !fullName.isEmpty {
            lines.append("    gecos: \(yaml(fullName))")
        }
        lines.append("    shell: /bin/bash")
        lines.append("    sudo: \(yaml("ALL=(ALL) NOPASSWD:ALL"))")
        lines.append("    lock_passwd: \(password == nil ? "true" : "false")")
        if !authorizedKeys.isEmpty {
            lines.append("    ssh_authorized_keys:")
            for key in authorizedKeys {
                lines.append("      - \(yaml(key))")
            }
        }

        if let password {
            lines.append("ssh_pwauth: true")
            lines.append("chpasswd:")
            lines.append("  expire: false")
            lines.append("  users:")
            lines.append("    - name: \(yaml(userName))")
            lines.append("      password: \(yaml(password))")
            lines.append("      type: text")
        } else {
            lines.append("ssh_pwauth: false")
        }

        lines.append("growpart:")
        lines.append("  mode: auto")
        lines.append("  devices: [\"/\"]")

        var mounts: [String] = []
        var commands: [String] = []
        if let sharedFoldersTag {
            let mountPoint = GuestIntegration.sharedFoldersMountPoint
            mounts.append("  - [\(yaml(sharedFoldersTag)), \(yaml(mountPoint)), virtiofs, \"rw,nofail\", \"0\", \"0\"]")
        }
        if let rosettaTag {
            let mountPoint = GuestIntegration.rosettaMountPoint
            mounts.append("  - [\(yaml(rosettaTag)), \(yaml(mountPoint)), virtiofs, \"ro,nofail\", \"0\", \"0\"]")
            commands.append(Self.rosettaRegistrationCommand(mountPoint: mountPoint))
        }
        if !mounts.isEmpty {
            lines.append("mounts:")
            lines.append(contentsOf: mounts)
        }
        var files: [String] = []
        // Below 1000, as a Mac user's ID is, login screens take an account for one of the system's
        // and leave it out of their list of people. These say it is a person's.
        if let userID, userID < Self.firstPersonID {
            files.append("  - path: \(yaml("/var/lib/AccountsService/users/" + userName))")
            files.append("    content: \(yaml("[User]\nSystemAccount=false\n"))")
            files.append("  - path: \(yaml(Self.loginScreenSettingsPath))")
            // Below 1000 are also accounts of services, which have no shell to sign in with.
            files.append("    content: \(yaml("[Users]\nMinimumUid=\(userID)\nHideShells=\(Self.shellsOfServices)\n"))")
        }
        if kernelMessagesOnSerialConsole {
            files.append("  - path: \(yaml(Self.serialConsoleSettingsPath))")
            files.append("    content: \(yaml(Self.serialConsoleSettings))")
            // The boot menu is only written anew when asked, and read at the next boot.
            commands.append(Self.bootMenuUpdateCommand)
        }
        if !setupScripts.isEmpty, let setupFiles = try? LinuxGuestSetup.files(for: setupScripts, userName: userName) {
            for file in setupFiles {
                files.append("  - path: \(yaml(file.path))")
                files.append("    encoding: b64")
                files.append("    content: \(yaml(Data(file.contents.utf8).base64EncodedString()))")
                files.append("    permissions: \(yaml(file.permissions))")
            }
            // Ahead of the guest agent, so that the first thing the agent has to tell is that a setup
            // is to come. The scripts themselves only run once all of this is over.
            commands.append(LinuxGuestSetup.scheduleCommand)
        }
        if let guestAgentInstaller {
            // Base64 carries the script through YAML untouched, whatever is in it.
            files.append("  - path: \(yaml(LinuxGuestAgent.installerPath))")
            files.append("    encoding: b64")
            files.append("    content: \(yaml(Data(guestAgentInstaller.utf8).base64EncodedString()))")
            files.append("    permissions: \(yaml("0755"))")
            // A guest that can't run the agent (no Python, say) is still a guest that works.
            commands.append("sh \(LinuxGuestAgent.installerPath) || true")
        }
        if !files.isEmpty {
            lines.append("write_files:")
            lines.append(contentsOf: files)
        }
        if !commands.isEmpty {
            lines.append("runcmd:")
            for command in commands {
                lines.append("  - \(yaml(command))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Netplan-style network configuration; `nil` leaves cloud-init's default (DHCP on the first interface).
    ///
    /// The interface identifies itself to DHCP by MAC address. The default (a generated client ID) would
    /// never match the host's MAC-based address reservation.
    public var networkConfig: String? {
        macAddress.map(Self.networkConfig)
    }

    static func networkConfig(macAddress: String) -> String {
        """
        version: 2
        ethernets:
          primary:
            match:
              macaddress: \(yaml(macAddress.lowercased()))
            dhcp4: true
            dhcp6: true
            dhcp-identifier: mac

        """
    }

    /// Writes the seed ISO (volume label `cidata`) at `url`.
    public func writeImage(to url: URL) throws {
        if !setupScripts.isEmpty {
            // Without them the machine would come up without what was asked for, and say nothing.
            _ = try LinuxGuestSetup.files(for: setupScripts, userName: userName)
        }
        var files: [String: Data] = [
            Self.metaDataFileName: Data(metaData.utf8),
            Self.userDataFileName: Data(userData.utf8),
        ]
        if let networkConfig {
            files[Self.networkConfigFileName] = Data(networkConfig.utf8)
        }
        try ISOImageBuilder.makeISO(volumeName: Self.volumeName, files: files, at: url)
    }

    // MARK: Copies

    static let volumeName = "cidata"
    static let metaDataFileName = "meta-data"
    static let userDataFileName = "user-data"
    static let networkConfigFileName = "network-config"

    /// Rewrites the seed image at `url` for a copy of the machine it was written for.
    ///
    /// The copy shares the original's disk, so as far as it knows it *is* the original. A new instance ID
    /// makes cloud-init treat the next start as a first boot: it takes the new host name, configures the
    /// network for the new MAC address and generates SSH host keys of its own.
    ///
    /// The account is left out of the new seed. It is on the copied disk already, as it is today, and
    /// setting it up again would bring back the password and sign-in rules of the day the original was made.
    ///
    /// The copy runs its first-boot setup again, and with it the installer of the guest agent that the
    /// seed carries. That is replaced by this build's, so that the copy of a machine made long ago doesn't
    /// put an agent of that day over the one on its disk.
    ///
    /// A setup script in the seed stays there. It isn't run a second time: what runs it finds on the
    /// copied disk that it has been at work there before.
    public static func reissue(
        at url: URL, hostName: String, macAddress: String?, instanceID: String = UUID().uuidString.lowercased(),
        guestAgentInstaller: String? = try? LinuxGuestAgent.installer()
    ) throws {
        var userData = try ISOImageBuilder.text(of: userDataFileName, in: url)
        userData = removingAccountSetup(from: replacingHostName(in: userData, with: hostName))
        if let guestAgentInstaller {
            userData = replacingGuestAgentInstaller(in: userData, with: guestAgentInstaller)
        }
        var files: [String: Data] = [
            metaDataFileName: Data(metaData(instanceID: instanceID, hostName: hostName).utf8),
            userDataFileName: Data(userData.utf8),
        ]
        if let macAddress {
            files[networkConfigFileName] = Data(networkConfig(macAddress: macAddress).utf8)
        }
        try ISOImageBuilder.makeISO(volumeName: volumeName, files: files, at: url)
    }

    /// Changes the `hostname:` line of a cloud-config document written by ``userData``.
    static func replacingHostName(in userData: String, with hostName: String) -> String {
        userData
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("hostname:") ? "hostname: \(yaml(hostName))" : String($0) }
            .joined(separator: "\n")
    }

    /// Puts `installer` in the place of the guest agent's installer in a cloud-config document written by
    /// ``userData``. A document that carries none stays as it is.
    static func replacingGuestAgentInstaller(in userData: String, with installer: String) -> String {
        var lines = userData.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let content = "    content: "
        guard let path = lines.firstIndex(of: "  - path: \(yaml(LinuxGuestAgent.installerPath))"),
              let index = lines[path...].dropFirst().prefix(3).firstIndex(where: { $0.hasPrefix(content) })
        else { return userData }
        lines[index] = content + yaml(Data(installer.utf8).base64EncodedString())
        return lines.joined(separator: "\n")
    }

    // MARK: Account

    /// What is wrong with `userName` as the name of the account to create, or `nil` if it will do.
    public static func problem(withUserName userName: String) -> String? {
        guard let first = userName.first else { return "Enter a user name." }
        let isValid = first.isASCII && first.isLowercase
            && userName.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
            && userName.count <= 32
        if !isValid {
            return "Use lowercase letters, digits, “-” and “_”, starting with a letter."
        }
        if userName == "root" {
            return "Choose a user name other than root."
        }
        return nil
    }

    /// A name for the account that is as close to `name` as the rules allow, for when nobody is asked:
    /// `Jane.Doe`, as a Mac may call its user, becomes `janedoe`.
    public static func userName(from name: String) -> String {
        let kept = name.lowercased().filter { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
        let candidate = String(kept.drop { !$0.isLowercase }.prefix(32))
        return problem(withUserName: candidate) == nil ? candidate : "user"
    }

    // MARK: Helpers

    /// Where a guest that boots with GRUB picks up additions to the kernel's command line. Its name sorts
    /// after the settings the cloud images bring, so that what it adds comes last.
    static let serialConsoleSettingsPath = "/etc/default/grub.d/99-swiftvm-console.cfg"

    /// Adds the serial console (`hvc0`) to the consoles the kernel writes its messages to.
    ///
    /// The display (`tty1`) is named once more after it. The console named last is the one systemd reports
    /// to and the one an emergency shell comes up on, and that has to stay where someone is looking.
    static let serialConsoleSettings = """
        # Added by SwiftVM. Kernel messages also go to the serial console (hvc0), where
        # "swiftvm console" and the virtual machine's console log pick them up. tty1 is
        # named last so that the display stays the system console.
        GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT console=hvc0 console=tty1"

        """

    /// The first user ID that systems give people rather than services.
    static let firstPersonID = 1000
    /// SDDM's settings for whom it lists. Read whenever it starts, and there to stay should it be
    /// installed later.
    static let loginScreenSettingsPath = "/etc/sddm.conf.d/90-swiftvm-users.conf"
    static let shellsOfServices = "/usr/bin/nologin,/usr/sbin/nologin,/sbin/nologin,/bin/false,/usr/bin/false"

    static let bootMenuUpdateCommand = "command -v update-grub >/dev/null && update-grub || true"

    /// Registers Rosetta with binfmt_misc so the kernel runs x86-64 ELF binaries through it.
    ///
    /// Debian and Ubuntu do that with `update-binfmts`. A system without it (Arch Linux) gets a file
    /// for systemd-binfmt instead, which is told to wait for Rosetta's share at every start: the kernel
    /// opens the program as it is registered, so it has to be there by then.
    static func rosettaRegistrationCommand(mountPoint: String) -> String {
        let magic = #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
        let mask = #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
        let interpreter = "\(mountPoint)/rosetta"
        let updateBinfmts = "update-binfmts --install rosetta \(interpreter)"
            + " --magic '\(magic)' --mask '\(mask)' --credentials yes --preserve no --fix-binary yes"
        // The same registration in binfmt.d's words: C for --credentials, F for --fix-binary.
        let binfmtFile = "printf '%s\\n' ':rosetta:M::\(magic):\(mask):\(interpreter):CF' > /etc/binfmt.d/rosetta.conf"
        let dropIn = "/etc/systemd/system/systemd-binfmt.service.d"
        let waitForShare = "mkdir -p \(dropIn) && printf '[Unit]\\nAfter=%s\\n'"
            + " \"$(systemd-escape --path --suffix=mount \(mountPoint))\" > \(dropIn)/rosetta.conf"
        return "if command -v update-binfmts >/dev/null; then \(updateBinfmts); else \(binfmtFile) && \(waitForShare)"
            + " && systemctl daemon-reload && systemctl restart systemd-binfmt; fi || true"
    }

    /// Takes the sections that create the account and set its password out of a cloud-config document
    /// written by ``userData``, and tells cloud-init to create no account at all (without that it would
    /// add the image's default one).
    static func removingAccountSetup(from userData: String) -> String {
        let accountSections: Set<Substring> = ["users", "chpasswd", "ssh_pwauth"]
        var lines: [String] = []
        var isInAccountSection = false
        for line in userData.split(separator: "\n", omittingEmptySubsequences: false) {
            // A section starts at the left margin and runs until the next line that does.
            if let first = line.first, first != " " {
                let key = line.prefix { $0 != ":" }
                isInAccountSection = accountSections.contains(key)
                if key == "users" {
                    lines.append("users: []")
                }
            }
            if line.isEmpty || !isInAccountSection {
                lines.append(String(line))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Encodes a scalar as a double-quoted YAML string (JSON string syntax is valid YAML).
    private func yaml(_ value: String) -> String {
        Self.yaml(value)
    }

    private static func yaml(_ value: String) -> String {
        let data = (try? JSONEncoder.yamlScalar.encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension JSONEncoder {
    static let yamlScalar: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
