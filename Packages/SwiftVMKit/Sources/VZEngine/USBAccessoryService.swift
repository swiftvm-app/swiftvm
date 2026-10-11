import AccessoryAccess
import Foundation
import IOKit
import Security
import VMCore

/// The USB devices that this Mac has given the app, as Apple's AccessoryAccess framework reports them.
///
/// Which devices an app gets is decided by the person at the Mac, in a place macOS provides (Virtual
/// Machine Accessories): a device is used with this Mac or with one app. The app is told of the devices
/// that are its own, and of each one that comes or goes after that. What it is told about can be handed
/// to a guest (``VZBackend``).
///
/// All of it takes the entitlement `com.apple.developer.accessory-access.usb`, which only counts in an
/// app with a provisioning profile; `scripts/bundle-app.sh` adds both when there is a profile.
@MainActor
public final class USBAccessoryService {
    public static let entitlement = "com.apple.developer.accessory-access.usb"

    /// Whether this program is signed to take USB devices. Without that there is nothing to ask macOS.
    public static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
    }

    /// Called for every device the app has when it starts listening, and for each that comes later.
    public var onConnect: (@MainActor (USBDevice) -> Void)?
    public var onDisconnect: (@MainActor (USBDevice.ID) -> Void)?

    private var accessories: [USBDevice.ID: AAUSBAccessory] = [:]
    private var listener: Listener?

    public init() {}

    /// Starts listening. Returns once macOS has agreed, and throws what it answers when it won't have
    /// the app listen. The devices the app has already are reported like those that come later.
    public func start() async throws {
        guard listener == nil else { return }
        let listener = Listener { [weak self] accessory, isConnected in
            guard let self else { return }
            if isConnected {
                add(accessory)
            } else {
                remove(accessory)
            }
        }
        // No criteria: every kind of device.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: []) { accessories, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // The same way the later ones come, so that they stay in order with them.
                for accessory in accessories {
                    listener.usbAccessoryDidConnect(accessory)
                }
                continuation.resume()
            }
        }
        self.listener = listener
    }

    /// The framework's own object for a device, which is what the Virtualization framework takes.
    func accessory(for id: USBDevice.ID) -> AAUSBAccessory? {
        accessories[id]
    }

    private func add(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        // A device that was there when listening began may be reported a second time as it comes.
        guard accessories.updateValue(accessory, forKey: id) == nil else { return }
        onConnect?(Self.device(for: accessory))
    }

    private func remove(_ accessory: AAUSBAccessory) {
        guard accessories.removeValue(forKey: accessory.registryID) != nil else { return }
        onDisconnect?(accessory.registryID)
    }

    /// What there is to know of a device: its numbers from the descriptor it handed over, and what it
    /// calls itself from the I/O registry, where macOS has written down the strings it read from it.
    private static func device(for accessory: AAUSBAccessory) -> USBDevice {
        let descriptor = USBDeviceDescriptor(accessory.deviceDescriptorData)
        var strings: [String: String] = [:]
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(accessory.registryID))
        if entry != 0 {
            defer { IOObjectRelease(entry) }
            for key in ["USB Product Name", "USB Vendor Name", "USB Serial Number"] {
                strings[key] = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            }
        }
        return USBDevice(
            id: accessory.registryID,
            vendorID: descriptor?.vendorID ?? 0,
            productID: descriptor?.productID ?? 0,
            name: strings["USB Product Name"],
            manufacturer: strings["USB Vendor Name"],
            serialNumber: strings["USB Serial Number"]
        )
    }
}

/// What the framework calls, on a queue of its own, when a device comes or goes. It passes each on to
/// the main queue, one after the other as they came.
private final class Listener: NSObject, AAUSBAccessoryListener, Sendable {
    private let report: @MainActor @Sendable (AAUSBAccessory, _ isConnected: Bool) -> Void

    init(report: @escaping @MainActor @Sendable (AAUSBAccessory, _ isConnected: Bool) -> Void) {
        self.report = report
    }

    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [report] in MainActor.assumeIsolated { report(usbAccessory, true) } }
    }

    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [report] in MainActor.assumeIsolated { report(usbAccessory, false) } }
    }
}
