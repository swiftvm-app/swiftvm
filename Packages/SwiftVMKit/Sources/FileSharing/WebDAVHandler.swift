import Foundation

/// One HTTP request, as the server has read it.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    /// The path as it was sent, still percent-encoded, without the query.
    public var path: String
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data
    /// A body too long to keep in memory, in a file of its own.
    public var bodyFile: URL?

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data(), bodyFile: URL? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// What the server answers.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [(String, String)]
    public enum Body: Sendable, Hashable {
        case data(Data)
        /// Part of a file, read as it is sent. The file is open already: what the handler looked at is
        /// what is sent, whatever is put at its path in the meantime.
        case file(FileHandle, offset: UInt64, length: UInt64)
    }
    public var body: Body

    public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (left: HTTPResponse, right: HTTPResponse) -> Bool {
        left.status == right.status && left.body == right.body && left.headers.map { "\($0.0):\($0.1)" } == right.headers.map { "\($0.0):\($0.1)" }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(status)
        hasher.combine(body)
    }

    public var bodyLength: UInt64 {
        switch body {
        case .data(let data): UInt64(data.count)
        case .file(_, _, let length): length
        }
    }
}

/// A folder of the Mac's that a guest sees, by the name it sees it under.
public struct SharedLocation: Sendable, Hashable {
    public var name: String
    public var url: URL
    public var readOnly: Bool

    public init(name: String, url: URL, readOnly: Bool) {
        self.name = name
        self.url = url
        self.readOnly = readOnly
    }
}

/// What WebDAV asks of the Mac's shared folders, and the answers, without the network: the folders a
/// guest is given appear as folders at the root of what it maps, as they do in a macOS guest.
///
/// This is the part of WebDAV that Windows' own client uses (class 1 and 2): Explorer reads folders
/// with `PROPFIND`, files with ranged `GET`, writes whole files with `PUT`, and Office takes a lock
/// before it saves. Locks are handed out and never kept to: a folder of the Mac's has nobody else
/// writing to it through WebDAV.
public struct WebDAVHandler: Sendable {
    public var locations: [SharedLocation]
    /// Where the shared folders are in the server's paths: `/` and a secret of the guest's. Links in
    /// answers keep it.
    public var prefix: String

    public init(locations: [SharedLocation], prefix: String = "") {
        self.locations = locations
        self.prefix = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
    }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            switch request.method.uppercased() {
            case "OPTIONS": return options()
            case "PROPFIND": return try propfind(request)
            case "GET": return try get(request, includingBody: true)
            case "HEAD": return try get(request, includingBody: false)
            case "PUT": return try put(request)
            case "MKCOL": return try makeCollection(request)
            case "DELETE": return try delete(request)
            case "MOVE": return try transfer(request, moving: true)
            case "COPY": return try transfer(request, moving: false)
            case "PROPPATCH": return try proppatch(request)
            case "LOCK": return lock(request)
            case "UNLOCK": return HTTPResponse(status: 204)
            default: return HTTPResponse(status: 405)
            }
        } catch let failure as Failure {
            return HTTPResponse(status: failure.status)
        } catch {
            return HTTPResponse(status: Self.status(for: error))
        }
    }

    struct Failure: Error {
        var status: Int
    }

    // MARK: Paths

    /// Where a path leads: the root that lists the shared folders, or a place in one of them.
    enum Place: Equatable {
        case root
        case item(SharedLocation, URL)
    }

    /// The place `path` names. A path that leads out of its shared folder leads nowhere: with `..`, with
    /// a `/` that was encoded into a name, or through a link.
    func place(for path: String) throws -> Place {
        guard path == prefix || path.hasPrefix(prefix + "/") else { throw Failure(status: 404) }
        let parts = path.dropFirst(prefix.count).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = parts.first else { return .root }
        guard let location = locations.first(where: { $0.name == first }) else { throw Failure(status: 404) }
        let rest = parts.dropFirst()
        guard !rest.contains(where: { $0 == ".." || $0 == "." || $0.contains("/") || $0.contains("\0") }) else { throw Failure(status: 403) }
        let url = rest.reduce(location.url.standardizedFileURL) { $0.appending(path: $1, directoryHint: .inferFromPath) }
        guard Self.isInside(url, folder: location.url) else { throw Failure(status: 403) }
        return .item(location, url)
    }

    /// Whether `url` is in `folder` once links are followed. A link inside the folder that leads out of
    /// it doesn't take the guest along. Of a place that isn't there yet, what counts is the folder it
    /// would be made in, and a link that leads nowhere counts as outside: what is written to it would
    /// be made wherever it points.
    static func isInside(_ url: URL, folder: URL) -> Bool {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        var existing = url
        var information = stat()
        while lstat(existing.path, &information) != 0 {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return false }
            existing = parent
        }
        if information.st_mode & S_IFMT == S_IFLNK, !FileManager.default.fileExists(atPath: existing.path) {
            return false
        }
        let resolved = existing.resolvingSymlinksInPath().path
        return resolved == base || resolved.hasPrefix(base + "/")
    }

    private func writable(_ path: String) throws -> URL {
        guard case .item(let location, let url) = try place(for: path) else { throw Failure(status: 403) }
        guard !location.readOnly else { throw Failure(status: 403) }
        guard url.standardizedFileURL != location.url.standardizedFileURL else { throw Failure(status: 403) }
        return url
    }

    // MARK: Methods

    private func options() -> HTTPResponse {
        HTTPResponse(status: 200, headers: [
            ("DAV", "1, 2"),
            ("MS-Author-Via", "DAV"),
            ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK"),
        ])
    }

    private func propfind(_ request: HTTPRequest) throws -> HTTPResponse {
        let depth = request.header("Depth") ?? "1"
        var entries: [Entry] = []
        let base = request.path.hasSuffix("/") ? request.path : request.path + "/"
        switch try place(for: request.path) {
        case .root:
            entries.append(Entry(href: base, name: "", isFolder: true, size: 0, modified: Date()))
            if depth != "0" {
                for location in locations {
                    let modified = (try? location.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    entries.append(Entry(href: base + Self.encoded(location.name) + "/", name: location.name, isFolder: true, size: 0, modified: modified))
                }
            }
        case .item(_, let url):
            guard let entry = Self.entry(at: url, href: request.path) else { throw Failure(status: 404) }
            entries.append(entry)
            if depth != "0", entry.isFolder {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Self.keys, options: [])
                for child in children {
                    let name = child.lastPathComponent
                    if let childEntry = Self.entry(at: child, href: base + Self.encoded(name)) {
                        entries.append(childEntry)
                    }
                }
            }
        }
        return HTTPResponse(status: 207, headers: [("Content-Type", "application/xml; charset=utf-8")], body: .data(Data(Self.multistatus(entries).utf8)))
    }

    private func get(_ request: HTTPRequest, includingBody: Bool) throws -> HTTPResponse {
        guard case .item(_, let url) = try place(for: request.path) else {
            return HTTPResponse(status: 200, headers: [("Content-Type", "text/plain")], body: .data(Data()))
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isDirectory != true else { throw Failure(status: 405) }
        let size = UInt64(values.fileSize ?? 0)
        var headers = [
            ("Accept-Ranges", "bytes"),
            ("Content-Type", "application/octet-stream"),
            ("Last-Modified", Self.httpDate(values.contentModificationDate ?? Date())),
            ("ETag", Self.etag(size: size, modified: values.contentModificationDate)),
        ]
        var offset: UInt64 = 0
        var length = size
        var status = 200
        if let range = request.header("Range"), let (start, end) = Self.range(range, size: size) {
            offset = start
            length = end - start + 1
            status = 206
            headers.append(("Content-Range", "bytes \(start)-\(end)/\(size)"))
        } else if request.header("Range") != nil, size > 0 {
            return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")])
        }
        headers.append(("Content-Length", String(length)))
        guard includingBody else { return HTTPResponse(status: status, headers: headers) }
        return HTTPResponse(status: status, headers: headers, body: .file(try FileHandle(forReadingFrom: url), offset: offset, length: length))
    }

    private func put(_ request: HTTPRequest) throws -> HTTPResponse {
        let url = try writable(request.path)
        var isDirectory: ObjCBool = false
        let existed = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else { throw Failure(status: 405) }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw Failure(status: 409) }
        if let file = request.bodyFile {
            if existed {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: file)
            } else {
                try FileManager.default.moveItem(at: file, to: url)
            }
        } else {
            try request.body.write(to: url, options: .atomic)
        }
        return HTTPResponse(status: existed ? 204 : 201)
    }

    private func makeCollection(_ request: HTTPRequest) throws -> HTTPResponse {
        let url = try writable(request.path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure(status: 405) }
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw Failure(status: 409) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return HTTPResponse(status: 201)
    }

    private func delete(_ request: HTTPRequest) throws -> HTTPResponse {
        let url = try writable(request.path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(status: 404) }
        try Self.discard(url)
        return HTTPResponse(status: 204)
    }

    /// Into the Trash, where something deleted or written over by mistake in the guest can be found
    /// again.
    private static func discard(_ url: URL) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func transfer(_ request: HTTPRequest, moving: Bool) throws -> HTTPResponse {
        let source = moving ? try writable(request.path) : try readable(request.path)
        guard FileManager.default.fileExists(atPath: source.path) else { throw Failure(status: 404) }
        guard let destinationHeader = request.header("Destination"),
              let destinationPath = URLComponents(string: destinationHeader)?.percentEncodedPath ?? Optional(destinationHeader)
        else { throw Failure(status: 400) }
        let destination = try writable(destinationPath)
        guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else { throw Failure(status: 409) }
        let overwrites = (request.header("Overwrite") ?? "T").uppercased() != "F"
        // The Mac's disk doesn't tell names apart by their case: a rename that only changes the case
        // finds the file itself where it goes.
        if Self.isSameItem(source, destination) {
            guard moving else { throw Failure(status: 403) }
            try FileManager.default.moveItem(at: source, to: destination)
            return HTTPResponse(status: 201)
        }
        let existed = FileManager.default.fileExists(atPath: destination.path)
        if existed {
            guard overwrites else { throw Failure(status: 412) }
            try Self.discard(destination)
        }
        if moving {
            try FileManager.default.moveItem(at: source, to: destination)
        } else {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return HTTPResponse(status: existed ? 204 : 201)
    }

    private static func isSameItem(_ one: URL, _ other: URL) -> Bool {
        var first = stat()
        var second = stat()
        guard lstat(one.path, &first) == 0, lstat(other.path, &second) == 0 else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private func readable(_ path: String) throws -> URL {
        guard case .item(_, let url) = try place(for: path) else { throw Failure(status: 403) }
        return url
    }

    /// Windows sets a file's times after writing it. The Mac keeps its own; every property counts as set.
    private func proppatch(_ request: HTTPRequest) throws -> HTTPResponse {
        _ = try place(for: request.path)
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(Self.xml(request.path))</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        return HTTPResponse(status: 207, headers: [("Content-Type", "application/xml; charset=utf-8")], body: .data(Data(body.utf8)))
    }

    private func lock(_ request: HTTPRequest) -> HTTPResponse {
        let token = "opaquelocktoken:" + UUID().uuidString.lowercased()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:timeout>Second-3600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>
        """
        return HTTPResponse(status: 200, headers: [("Lock-Token", "<\(token)>"), ("Content-Type", "application/xml; charset=utf-8")], body: .data(Data(body.utf8)))
    }

    // MARK: Listings

    struct Entry {
        var href: String
        var name: String
        var isFolder: Bool
        var size: UInt64
        var modified: Date
    }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

    static func entry(at url: URL, href: String) -> Entry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isFolder = values.isDirectory == true
        return Entry(
            href: isFolder && !href.hasSuffix("/") ? href + "/" : href, name: url.lastPathComponent, isFolder: isFolder,
            size: UInt64(values.fileSize ?? 0), modified: values.contentModificationDate ?? Date()
        )
    }

    static func multistatus(_ entries: [Entry]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">"
        for entry in entries {
            xml += "<D:response><D:href>\(Self.xml(entry.href))</D:href><D:propstat><D:prop>"
            xml += "<D:displayname>\(Self.xml(entry.name))</D:displayname>"
            xml += "<D:getlastmodified>\(httpDate(entry.modified))</D:getlastmodified>"
            xml += "<D:creationdate>\(isoDate(entry.modified))</D:creationdate>"
            if entry.isFolder {
                xml += "<D:resourcetype><D:collection/></D:resourcetype>"
            } else {
                xml += "<D:resourcetype/><D:getcontentlength>\(entry.size)</D:getcontentlength>"
                xml += "<D:getcontenttype>application/octet-stream</D:getcontenttype>"
                xml += "<D:getetag>\(etag(size: entry.size, modified: entry.modified))</D:getetag>"
            }
            xml += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
            xml += "</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }
        return xml + "</D:multistatus>"
    }

    // MARK: Helpers

    /// A path component as a link has it: everything but what may stand in a path as it is, encoded.
    static func encoded(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func etag(size: UInt64, modified: Date?) -> String {
        "\"\(size)-\(Int64((modified ?? Date()).timeIntervalSince1970 * 1000))\""
    }

    static func httpDate(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated), \(day: .twoDigits) \(month: .abbreviated) \(year: .defaultDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits) GMT",
            locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "GMT")!, calendar: Calendar(identifier: .gregorian)
        ))
    }

    static func isoDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// The first and last byte a `Range` header asks for, within a file of `size` bytes.
    static func range(_ header: String, size: UInt64) -> (UInt64, UInt64)? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = UInt64(parts[1]), suffix > 0 {
            return (size - min(suffix, size), size - 1)
        }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        let end = parts[1].isEmpty ? size - 1 : min(UInt64(parts[1]) ?? (size - 1), size - 1)
        return end >= start ? (start, end) : nil
    }

    static func status(for error: any Error) -> Int {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return 500 }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return 404
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return 403
        case NSFileWriteOutOfSpaceError: return 507
        default: return 500
        }
    }
}
