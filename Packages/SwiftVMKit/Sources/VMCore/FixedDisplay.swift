extension VirtualMachine {
    /// Changes a stopped machine's saved panel. The guest chooses its own logical UI scaling.
    public func setFixedDisplay(widthInPixels: Int, heightInPixels: Int, pixelsPerInch: Int) async throws {
        try await whileStopped(.changingDisplay) {
            // Stale memory can exist even when the controller believes the machine is stopped.
            guard !bundle.hasSavedState else {
                throw VMError.invalidConfiguration("Discard saved state before changing the display.")
            }
            guard widthInPixels > 0, heightInPixels > 0, pixelsPerInch > 0 else {
                throw VMError.invalidConfiguration("Display width, height and pixel density must be positive integers.")
            }
            guard let backendProvider else { throw VMError.noBackendProvider }
            var updated = configuration
            updated.display.widthInPixels = widthInPixels
            updated.display.heightInPixels = heightInPixels
            updated.display.pixelsPerInch = pixelsPerInch
            updated.display.automaticallyResizes = false
            try backendProvider.validateFixedDisplay(updated, in: bundle)
            try updateConfiguration { $0.display = updated.display }
        }
    }
}
