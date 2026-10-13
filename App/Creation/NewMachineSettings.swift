import AppKit
import Installers
import VMCore
import VZEngine

/// Whether extra fields are expanded. Raw values preserve the saved preference.
enum NewMachineMode: String {
    case simple = "Simple"
    case advanced = "Advanced"

    /// The forms scroll within the same space when the source changes.
    var formHeight: CGFloat { self == .simple ? 480 : 680 }
}

/// Editable macOS settings, independent of which controls are expanded.
struct MacMachineSettings {
    var cpuCount = HostResources.recommendedCPUCount(for: .macOS)
    var memoryGigabytes = Double(HostResources.recommendedMemorySize(for: .macOS) / HostResources.gibibyte)
    var diskGigabytes = Int(HostResources.recommendedDiskCapacity(for: .macOS) / HostResources.gibibyte)
    var fullName: String
    var userName: String
    var password = ""
    var logsInAutomatically = true
    var installsSSHKey = true
    var location: URL?

    init(hostUserName: String = NSUserName(), hostFullName: String = NSFullUserName()) {
        let candidate = GuestProvisioning.problem(withUserName: hostUserName) == nil
            ? hostUserName : CloudInitSeed.userName(from: hostUserName)
        userName = GuestProvisioning.problem(withUserName: candidate) == nil ? candidate : "user"
        fullName = hostFullName
    }

    var account: GuestProvisioning {
        let user = userName.trimmingCharacters(in: .whitespaces)
        let full = fullName.trimmingCharacters(in: .whitespaces)
        return GuestProvisioning(
            fullName: full.isEmpty ? user : full, userName: user, password: password,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: installsSSHKey
        )
    }

    /// Expanding or collapsing Advanced cannot change what will be installed.
    func request(name: String, image: MacRestoreImage?) -> MacInstallRequest {
        let account = account
        let provisionsAccount = image?.supportsProvisioning ?? true
        return MacInstallRequest(
            name: name,
            image: image,
            cpuCount: max(cpuCount, image?.requirements?.minimumCPUCount ?? 2),
            memorySize: max(UInt64(max(memoryGigabytes, 0)) * HostResources.gibibyte,
                image?.requirements?.minimumMemorySize ?? 4 * HostResources.gibibyte),
            diskCapacity: UInt64(max(diskGigabytes, 0)) * HostResources.gibibyte,
            account: provisionsAccount ? account : nil,
            installsSSHKey: provisionsAccount && account.enablesRemoteLogin,
            location: location
        )
    }
}

/// Editable template overrides. Untouched hardware stays exactly as saved in the template.
struct TemplateMachineSettings {
    var cpuCount: Int
    var memoryGigabytes: Double
    var diskGigabytes: Int
    var startsWhenReady = true
    var location: URL?

    init(template: VMTemplate) {
        cpuCount = template.configuration.cpuCount
        memoryGigabytes = Double(Self.memoryGigabytes(of: template))
        diskGigabytes = Self.diskGigabytes(of: template)
    }

    static func memoryGigabytes(of template: VMTemplate) -> Int {
        max(Int(template.configuration.memorySize / HostResources.gibibyte), 1)
    }

    static func diskGigabytes(of template: VMTemplate) -> Int {
        Int(((template.configuration.systemDisk?.capacity ?? 0) + HostResources.gibibyte - 1) / HostResources.gibibyte)
    }

    func request(name: String, template: VMTemplate) -> TemplateCreateRequest {
        return TemplateCreateRequest(
            name: name, template: template, cpuCount: cpuCount,
            // Memory that wasn't touched stays what the template has, to the byte.
            memorySize: Int(memoryGigabytes) == Self.memoryGigabytes(of: template)
                ? nil : UInt64(max(memoryGigabytes, 0)) * HostResources.gibibyte,
            diskCapacity: diskGigabytes > Self.diskGigabytes(of: template)
                ? UInt64(diskGigabytes) * HostResources.gibibyte : nil,
            location: location
        )
    }
}
