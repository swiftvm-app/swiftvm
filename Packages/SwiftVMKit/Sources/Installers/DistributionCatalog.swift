import Foundation

/// A downloadable disk image or installer.
public struct RemoteImage: Codable, Sendable, Hashable {
    public enum ChecksumAlgorithm: String, Codable, Sendable, Hashable {
        case sha256
        case sha512
    }

    public var url: URL
    /// A `SHA256SUMS`-style file listing the expected digest of `url`'s file name.
    public var checksumsURL: URL?
    public var checksumAlgorithm: ChecksumAlgorithm?

    public init(url: URL, checksumsURL: URL? = nil, checksumAlgorithm: ChecksumAlgorithm? = nil) {
        self.url = url
        self.checksumsURL = checksumsURL
        self.checksumAlgorithm = checksumAlgorithm
    }

    public var fileName: String { url.lastPathComponent }
}

/// A Linux distribution release the app knows how to set up.
public struct LinuxDistribution: Codable, Sendable, Hashable, Identifiable {
    public struct Installer: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var url: URL
        public var checksumsURL: URL?
        public var checksumAlgorithm: RemoteImage.ChecksumAlgorithm?

        public var id: URL { url }
        public var image: RemoteImage {
            RemoteImage(url: url, checksumsURL: checksumsURL, checksumAlgorithm: checksumAlgorithm)
        }
    }

    public var id: String
    /// Distribution family identifier, e.g. `ubuntu`.
    public var distribution: String
    /// Display name including the version, e.g. `Ubuntu 26.04 LTS`.
    public var name: String
    public var summary: String
    /// Pre-installed image configured on first boot by cloud-init (Quick Create).
    public var cloudImage: RemoteImage?
    /// Installer ISOs for a manual installation.
    public var installers: [Installer]
}

/// The built-in list of Linux distributions.
public enum DistributionCatalog {
    private struct File: Codable {
        var distributions: [LinuxDistribution]
    }

    /// Distributions bundled with the app.
    public static let builtIn: [LinuxDistribution] = {
        guard let url = Bundle.module.url(forResource: "distributions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.distributions
    }()

    /// Distributions that can be created without running an installer.
    public static var quickCreate: [LinuxDistribution] {
        builtIn.filter { $0.cloudImage != nil }
    }
}
