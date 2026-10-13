import AppKit

/// The system's panel for choosing a folder: where to keep a machine, new machines, or downloads.
enum FolderPanel {
    /// - Parameters:
    ///   - message: What the folder is for, above the list.
    ///   - prompt: The button that chooses.
    ///   - directory: The folder the panel opens in.
    /// - Returns: The folder that was chosen, which may have been made in the panel, or `nil`.
    static func choose(message: String, prompt: String = "Choose", startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = directory
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.standardizedFileURL
    }
}

extension URL {
    /// The path as it is shown: with `~` for the home folder.
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
