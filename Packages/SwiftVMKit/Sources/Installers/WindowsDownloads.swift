import Foundation

/// Where Windows and its drivers come from.
public enum WindowsDownloads {
    /// The disc of drivers for QEMU's virtual devices, signed for Windows by Red Hat. Windows on Arm has
    /// none of its own for the network card, the agent's serial line or the display. The project lists
    /// no checksum to check a download against, so the app knows the one of the version it was written for.
    public static let drivers = RemoteImage(
        url: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!,
        sha256: "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"
    )

    /// Windows as Microsoft offers it for download today.
    public struct Release: Sendable, Hashable {
        /// Such as `Windows 11 ARM 64 26H2 26300.9457`.
        public var name: String
        /// Microsoft's name for its language, such as `English`.
        public var language: String
        /// A link that works for a day.
        public var image: RemoteImage
    }

    public enum DownloadError: Error, LocalizedError, Equatable {
        /// Microsoft didn't hand out a link, in its own words.
        case refused(String)
        case unexpectedAnswer

        public var errorDescription: String? {
            switch self {
            case .refused(let reason):
                "Microsoft didn't let SwiftVM download Windows (\(reason)). This often happens over a VPN. Download the Windows 11 Arm64 ISO from Microsoft's website instead, and create the machine from that file."
            case .unexpectedAnswer:
                "Microsoft's download page answered in a way SwiftVM doesn't understand. Download the Windows 11 Arm64 ISO from Microsoft's website instead, and create the machine from that file."
            }
        }
    }

    /// The page people download Windows 11 for Arm from.
    public static let downloadPage = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!

    /// Asks Microsoft for a link to Windows 11 for Arm, in the first of `languages` it has, as its own
    /// download page does: the page has a session made for it, and Microsoft checks that the session
    /// is one a browser made before it hands out a link.
    public static func latest(preferring languages: [String] = Locale.preferredLanguages) async throws -> Release {
        let client = Client()
        let page = (try? await client.text(of: URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!)) ?? ""
        let edition = productEdition(inPage: page) ?? knownProductEdition
        let session = UUID().uuidString.lowercased()

        // What the page's scripts would do in a browser, in the order they do it.
        let fingerprint = try await client.text(of: URL(string: "https://ov-df.microsoft.com/mdt.js?instanceId=\(customer)&PageId=si&session_id=\(session)")!)
        if let address = fingerprintAddress(inScript: fingerprint, now: Date()) {
            _ = try? await client.data(from: address)
        }
        _ = try? await client.data(from: URL(string: "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=\(session)")!)

        let skus = try await client.json(from: connector(
            "getskuinformationbyproductedition", ["ProductEditionId": edition, "SKU": "undefined"], session: session
        ))
        try throwIfRefused(skus)
        let available = (skus["Skus"] as? [[String: Any]] ?? []).compactMap { sku -> (id: String, language: String)? in
            guard let id = sku["Id"] as? String, let language = sku["Language"] as? String else { return nil }
            return (id, language)
        }
        guard let language = skuLanguage(for: languages, available: available.map(\.language)),
              let sku = available.first(where: { $0.language == language })
        else { throw DownloadError.unexpectedAnswer }

        let links = try await client.json(
            from: connector("GetProductDownloadLinksBySku", ["productEditionId": "undefined", "SKU": sku.id], session: session),
            referer: downloadPage
        )
        try throwIfRefused(links)
        guard let option = (links["ProductDownloadOptions"] as? [[String: Any]])?.first,
              let address = (option["Uri"] as? String).flatMap(URL.init(string:))
        else { throw DownloadError.unexpectedAnswer }
        let name = option["ProductDisplayName"] as? String ?? "Windows 11"
        return Release(name: name, language: language, image: RemoteImage(url: address))
    }

    // MARK: Microsoft's download page

    /// The product edition the page offered when this was written, for when the page can't be read.
    static let knownProductEdition = "3816"
    static let customer = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let profile = "606624d44113"

    static func connector(_ method: String, _ parameters: [String: String], session: String) -> URL {
        var components = URLComponents(string: "https://www.microsoft.com/software-download-connector/api/\(method)")!
        var items = [URLQueryItem(name: "profile", value: profile)]
        for (name, value) in parameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        items += [
            URLQueryItem(name: "friendlyFileName", value: "undefined"),
            URLQueryItem(name: "Locale", value: "en-US"),
            URLQueryItem(name: "sessionID", value: session),
        ]
        components.queryItems = items
        return components.url!
    }

    /// The product edition the page lets people pick: the value of its first option for an Arm64 ISO.
    static func productEdition(inPage page: String) -> String? {
        let pattern = /<option value="(\d+)">[^<]*Arm64[^<]*</
        return page.firstMatch(of: pattern).map { String($0.1) }
    }

    /// Where the page's fingerprint script would send a browser, with the time it would add.
    static func fingerprintAddress(inScript script: String, now: Date) -> URL? {
        guard let address = script.firstMatch(of: /url:"([^"]+)"/).map({ String($0.1) }),
              let ticks = script.firstMatch(of: /rticks="\+(\d+)/).map({ String($0.1) })
        else { return nil }
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        return URL(string: "\(address)&mdt=\(milliseconds)&rticks=\(ticks)")
    }

    private static func throwIfRefused(_ answer: [String: Any]) throws {
        let errors = (answer["Errors"] as? [[String: Any]]) ?? ((answer["ValidationContainer"] as? [String: Any])?["Errors"] as? [[String: Any]]) ?? []
        if let first = errors.first {
            throw DownloadError.refused((first["Value"] as? String) ?? (first["Key"] as? String) ?? "no reason given")
        }
    }

    // MARK: Languages

    /// Microsoft's names for the languages it offers Windows in, by the language tags they stand for. A
    /// tag with a region comes before the language without one.
    static let languageNames: [(tag: String, name: String)] = [
        ("en-US", "English"), ("en", "English (United Kingdom)"), ("pt-BR", "Brazilian Portuguese"), ("pt", "Portuguese"),
        ("fr-CA", "French Canadian"), ("fr", "French"), ("es-MX", "Spanish (Mexico)"), ("es", "Spanish"),
        ("zh-Hans", "Chinese (Simplified)"), ("zh-Hant", "Chinese (Traditional)"), ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"), ("zh-HK", "Chinese (Traditional)"), ("sr-Latn", "Serbian Latin"), ("sr", "Serbian Latin"),
        ("ar", "Arabic"), ("bg", "Bulgarian"), ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"),
        ("et", "Estonian"), ("fi", "Finnish"), ("de", "German"), ("el", "Greek"), ("he", "Hebrew"), ("hu", "Hungarian"),
        ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("nb", "Norwegian"),
        ("no", "Norwegian"), ("pl", "Polish"), ("ro", "Romanian"), ("ru", "Russian"), ("sk", "Slovak"), ("sl", "Slovenian"),
        ("sv", "Swedish"), ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"),
    ]

    /// The first of `preferred` language tags that Microsoft offers Windows in, by its name for it, or
    /// English if none is.
    static func skuLanguage(for preferred: [String], available: [String]) -> String? {
        for tag in preferred {
            for (prefix, name) in languageNames where tag == prefix || tag.hasPrefix(prefix + "-") {
                if available.contains(name) { return name }
            }
        }
        return available.contains("English") ? "English" : available.first
    }

    // MARK: Asking

    /// Asks the way a browser does: Microsoft turns away what doesn't look like one.
    private struct Client {
        let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                "Accept-Language": "en-US,en;q=0.9",
            ]
            configuration.timeoutIntervalForRequest = 30
            return URLSession(configuration: configuration)
        }()

        func data(from url: URL, referer: URL? = nil) async throws -> Data {
            var request = URLRequest(url: url)
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DownloadError.refused("HTTP \(http.statusCode)")
            }
            return data
        }

        func text(of url: URL) async throws -> String {
            String(decoding: try await data(from: url), as: UTF8.self)
        }

        func json(from url: URL, referer: URL? = nil) async throws -> [String: Any] {
            let data = try await data(from: url, referer: referer)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DownloadError.unexpectedAnswer }
            return object
        }
    }
}
