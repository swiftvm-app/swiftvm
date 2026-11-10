import Foundation

enum PasswordInput {
    static let maximumLength = 4096

    enum Problem: Error, LocalizedError, Equatable {
        case empty, tooLong, invalidEncoding, invalidCharacters, unreadable

        var errorDescription: String? {
            switch self {
            case .empty: "Password stdin is empty."
            case .tooLong: "Password stdin exceeds 4096 password bytes."
            case .invalidEncoding: "Password stdin must be valid UTF-8."
            case .invalidCharacters: "Password stdin must be one line without NUL, with only an optional final LF or CRLF."
            case .unreadable: "Couldn't read the password from stdin."
            }
        }
    }

    /// Reads to EOF, allowing one final line ending without trimming password whitespace.
    static func read(from descriptor: Int32 = STDIN_FILENO) throws -> String {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            // One byte beyond the largest valid input detects excess, even if the pipe stays open.
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, maximumLength + 3 - bytes.count))
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                guard bytes.count <= maximumLength + 2 else { throw Problem.tooLong }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw Problem.unreadable
            }
        }
        if bytes.last == 10 {
            bytes.removeLast()
            if bytes.last == 13 { bytes.removeLast() }
        }
        guard !bytes.isEmpty else { throw Problem.empty }
        guard bytes.count <= maximumLength else { throw Problem.tooLong }
        guard let password = String(validating: bytes, as: UTF8.self) else { throw Problem.invalidEncoding }
        guard !bytes.contains(0), !bytes.contains(10), !bytes.contains(13) else { throw Problem.invalidCharacters }
        return password
    }
}
