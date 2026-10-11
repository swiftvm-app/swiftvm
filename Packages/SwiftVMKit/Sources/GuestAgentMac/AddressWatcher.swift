import Foundation
import SystemConfiguration

/// Says when the system's network addresses may have changed, so that nobody has to keep looking.
final class AddressWatcher: @unchecked Sendable {
    private final class Receiver {
        let onChange: () -> Void

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }
    }

    private let receiver: Receiver
    private var store: SCDynamicStore?

    /// - Parameter onChange: Called on `queue` when an address was added to or taken from a network card.
    ///   One change seldom comes alone.
    init?(queue: DispatchQueue, onChange: @escaping () -> Void) {
        receiver = Receiver(onChange: onChange)
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(receiver).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let store = SCDynamicStoreCreate(nil, "swiftvm-agent" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<Receiver>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context)
        let patterns = ["State:/Network/Interface/[^/]+/IPv4", "State:/Network/Interface/[^/]+/IPv6"] as CFArray
        guard let store, SCDynamicStoreSetNotificationKeys(store, nil, patterns), SCDynamicStoreSetDispatchQueue(store, queue) else {
            return nil
        }
        self.store = store
    }

    deinit {
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
    }
}
