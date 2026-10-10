import Foundation

/// Derives SSH host aliases and guest host names from machine names.
public enum SSHAlias {
    /// Converts a machine name into a lowercase, dash-separated alias, e.g. `Ubuntu 26.04` → `ubuntu-26-04`.
    ///
    /// The result is also a valid DNS label, so it doubles as the guest's host name.
    public static func slug(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        var pendingDash = false
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash, !slug.isEmpty {
                    slug.append("-")
                }
                slug.append(character)
                pendingDash = false
            } else if character == "'" || character == "’" {
                continue
            } else {
                pendingDash = true
            }
        }
        let limited = String(slug.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return limited.isEmpty ? "vm" : limited
    }

    /// Returns `base`, or `base-2`, `base-3`, … so that the result isn't in `taken`.
    public static func unique(_ base: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") {
            counter += 1
        }
        return "\(base)-\(counter)"
    }
}
