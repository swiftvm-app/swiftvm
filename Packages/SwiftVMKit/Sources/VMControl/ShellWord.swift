import Foundation

/// `word` as a shell takes it for one argument, for a command to be copied from a message: as it is
/// when it is plain, in single quotes otherwise.
public func shellWord(_ word: String) -> String {
    let plain = word.first.map { $0 != "=" && $0 != "~" } == true && word.unicodeScalars.allSatisfy {
        $0.isASCII && CharacterSet.alphanumerics.contains($0) || "-_.,:/@%+=".unicodeScalars.contains($0)
    }
    return plain ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
