import Foundation

/// One side of `swiftvm cp`: a path on this Mac, or one in a guest, written `<machine>:<path>`.
public enum CopyEndpoint: Sendable, Equatable {
    case local(String)
    case guest(machine: String, path: String)

    /// Reads what was typed. A colon makes it a place in a guest, as it does for `scp`, unless a slash
    /// comes before it: `./notes:old.txt` is a file here whose name has a colon in it.
    public init(_ text: String) {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex, !text[..<colon].contains("/") else {
            self = .local(text)
            return
        }
        self = .guest(machine: String(text[..<colon]), path: String(text[text.index(after: colon)...]))
    }
}
