import DiskTools
import Foundation
import VMCore

/// First-boot configuration for a Linux cloud image, delivered as a cloud-init NoCloud seed ISO.
public struct CloudInitSeed: Sendable, Hashable {
    public var hostName: String
    /// Changing the instance ID makes cloud-init run its first-boot setup again.
    public var instanceID: String
    public var userName: String
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

    public init(
        hostName: String,
        instanceID: String = UUID().uuidString.lowercased(),
        userName: String,
        fullName: String? = nil,
        password: String? = nil,
        authorizedKeys: [String] = [],
        macAddress: String? = nil,
        timeZone: String? = TimeZone.current.identifier,
        sharedFoldersTag: String? = GuestIntegration.sharedFoldersTag,
        rosettaTag: String? = nil
    ) {
        self.hostName = hostName
        self.instanceID = instanceID
        self.userName = userName
        self.fullName = fullName
        self.password = password
        self.authorizedKeys = authorizedKeys
        self.macAddress = macAddress
        self.timeZone = timeZone
        self.sharedFoldersTag = sharedFoldersTag
        self.rosettaTag = rosettaTag
    }

    // MARK: Documents

    public var metaData: String {
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
        guard let macAddress else { return nil }
        return """
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
        var files: [String: Data] = [
            "meta-data": Data(metaData.utf8),
            "user-data": Data(userData.utf8),
        ]
        if let networkConfig {
            files["network-config"] = Data(networkConfig.utf8)
        }
        try ISOImageBuilder.makeISO(volumeName: "cidata", files: files, at: url)
    }

    // MARK: Helpers

    /// Registers Rosetta with binfmt_misc so the kernel runs x86-64 ELF binaries through it.
    static func rosettaRegistrationCommand(mountPoint: String) -> String {
        let magic = #"\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00"#
        let mask = #"\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff"#
        return "command -v update-binfmts >/dev/null && update-binfmts --install rosetta \(mountPoint)/rosetta"
            + " --magic '\(magic)' --mask '\(mask)' --credentials yes --preserve no --fix-binary yes || true"
    }

    /// Encodes a scalar as a double-quoted YAML string (JSON string syntax is valid YAML).
    private func yaml(_ value: String) -> String {
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
