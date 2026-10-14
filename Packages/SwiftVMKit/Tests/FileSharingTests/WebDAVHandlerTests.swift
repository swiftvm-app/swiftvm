import Foundation
import Testing
@testable import FileSharing

@Suite struct WebDAVHandlerTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "swiftvm-webdav-\(UUID().uuidString)")

    private func handler() throws -> WebDAVHandler {
        let projects = directory.appending(path: "Projects")
        let photos = directory.appending(path: "Photos")
        try FileManager.default.createDirectory(at: projects.appending(path: "App"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("0123456789".utf8).write(to: projects.appending(path: "notes.txt"))
        try Data("secret".utf8).write(to: directory.appending(path: "outside.txt"))
        return WebDAVHandler(locations: [
            SharedLocation(name: "Projects", url: projects, readOnly: false),
            SharedLocation(name: "My Photos", url: photos, readOnly: true),
        ], prefix: "/abc123")
    }

    private func body(_ response: HTTPResponse) -> String {
        guard case .data(let data) = response.body else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test func listsTheSharedFoldersAtTheRootWithLinksThatKeepTheSecret() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try handler().handle(HTTPRequest(method: "PROPFIND", path: "/abc123/", headers: ["depth": "1"]))
        #expect(response.status == 207)
        let listing = body(response)
        #expect(listing.contains("<D:href>/abc123/Projects/</D:href>"))
        #expect(listing.contains("<D:href>/abc123/My%20Photos/</D:href>"))
        #expect(!listing.contains("outside"))

        let folder = try handler().handle(HTTPRequest(method: "PROPFIND", path: "/abc123/Projects", headers: ["depth": "1"]))
        #expect(body(folder).contains("<D:href>/abc123/Projects/notes.txt</D:href>"))
        #expect(body(folder).contains("<D:getcontentlength>10</D:getcontentlength>"))
    }

    @Test func readsAPartOfAFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try handler().handle(HTTPRequest(method: "GET", path: "/abc123/Projects/notes.txt", headers: ["range": "bytes=2-4"]))
        #expect(response.status == 206)
        #expect(response.body == .file(directory.appending(path: "Projects/notes.txt"), offset: 2, length: 3))
        #expect(response.headers.contains { $0.0 == "Content-Range" && $0.1 == "bytes 2-4/10" })
    }

    @Test func writesWhereItMayAndNowhereElse() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = try handler()
        let put = handler.handle(HTTPRequest(method: "PUT", path: "/abc123/Projects/App/main.swift", body: Data("print()".utf8)))
        #expect(put.status == 201)
        #expect(try String(contentsOf: directory.appending(path: "Projects/App/main.swift"), encoding: .utf8) == "print()")
        // A folder shared to read stays as it is.
        #expect(handler.handle(HTTPRequest(method: "PUT", path: "/abc123/My%20Photos/new.jpg", body: Data([1]))).status == 403)
        // Nothing leads out of a shared folder.
        #expect(handler.handle(HTTPRequest(method: "GET", path: "/abc123/Projects/../outside.txt")).status == 403)
        #expect(handler.handle(HTTPRequest(method: "DELETE", path: "/abc123/Projects")).status == 403)
        // Another machine's secret finds nothing here.
        #expect(handler.handle(HTTPRequest(method: "PROPFIND", path: "/other/Projects")).status == 404)
    }

    @Test func writesNothingOutsideTheFolderByAnyWay() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let handler = try handler()
        let elsewhere = directory.appending(path: "Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "Projects/Link"), withDestinationURL: elsewhere)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "Projects/Dangling"), withDestinationURL: elsewhere.appending(path: "made.txt")
        )
        let attempts = [
            // A `/` encoded into a name, which would make `..` of it once decoded.
            HTTPRequest(method: "PUT", path: "/abc123/Projects/..%2Fescaped.txt", body: Data([1])),
            HTTPRequest(method: "MKCOL", path: "/abc123/Projects/App%2F..%2F..%2Fescaped"),
            // A new file in a folder that a link leads out to, and a link that leads to nothing yet.
            HTTPRequest(method: "PUT", path: "/abc123/Projects/Link/new.txt", body: Data([1])),
            HTTPRequest(method: "PUT", path: "/abc123/Projects/Dangling", body: Data([1])),
            HTTPRequest(method: "MOVE", path: "/abc123/Projects/notes.txt", headers: ["destination": "/abc123/Projects/Link/notes.txt"]),
        ]
        for attempt in attempts {
            #expect(handler.handle(attempt).status == 403, "\(attempt.method) \(attempt.path)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "escaped").path))
    }

    @Test func aRenameThatOnlyChangesTheCaseKeepsTheFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try handler().handle(HTTPRequest(
            method: "MOVE", path: "/abc123/Projects/notes.txt", headers: ["destination": "/abc123/Projects/Notes.txt"]
        ))
        #expect(response.status == 201)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.appending(path: "Projects").path)
        #expect(names.contains("Notes.txt") && !names.contains("notes.txt"))
        #expect(try String(contentsOf: directory.appending(path: "Projects/Notes.txt"), encoding: .utf8) == "0123456789")
    }

    @Test func movesAFileWithinTheFolders() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = try handler().handle(HTTPRequest(
            method: "MOVE", path: "/abc123/Projects/notes.txt",
            headers: ["destination": "http://192.168.64.1:8080/abc123/Projects/App/notes.txt"]
        ))
        #expect(response.status == 201)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Projects/App/notes.txt").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Projects/notes.txt").path))
    }
}
