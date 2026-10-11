import Foundation

/// A USB device plugged into this Mac that a virtual machine can be handed.
public struct USBDevice: Sendable, Hashable, Identifiable {
    /// The device's number in this Mac's I/O registry. It is the device's for as long as it stays
    /// plugged in; plugged in again, the same device has another.
    public var id: UInt64
    public var vendorID: UInt16
    public var productID: UInt16
    /// What the device calls itself, or what it is by its numbers when it doesn't say.
    public var name: String
    public var manufacturer: String?
    public var serialNumber: String?

    public init(
        id: UInt64, vendorID: UInt16, productID: UInt16, name: String? = nil, manufacturer: String? = nil,
        serialNumber: String? = nil
    ) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.manufacturer = Self.cleaned(manufacturer)
        self.serialNumber = Self.cleaned(serialNumber)
        self.name = Self.cleaned(name) ?? "USB Device \(Self.identifier(vendorID: vendorID, productID: productID))"
    }

    /// Vendor and product the way they are usually written: `05ac:12a8`.
    public var identifier: String { Self.identifier(vendorID: vendorID, productID: productID) }

    static func identifier(vendorID: UInt16, productID: UInt16) -> String {
        String(format: "%04x:%04x", vendorID, productID)
    }

    /// Devices pad what they say of themselves with spaces, and some say nothing in many characters.
    private static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// What a USB device says of itself first: the device descriptor (USB 2.0, section 9.6.1), 18 bytes
/// with the low byte of every number first.
public struct USBDeviceDescriptor: Sendable, Hashable {
    public var vendorID: UInt16
    public var productID: UInt16
    /// The kind of device, from the USB-IF's list. Most say 0 here: "see my interfaces".
    public var deviceClass: UInt8

    public static let length = 18

    /// `nil` for bytes that aren't a device descriptor.
    public init?(_ data: Data) {
        let bytes = [UInt8](data.prefix(Self.length))
        guard bytes.count == Self.length, bytes[0] >= Self.length, bytes[1] == 1 else { return nil }
        deviceClass = bytes[4]
        vendorID = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
        productID = UInt16(bytes[10]) | UInt16(bytes[11]) << 8
    }
}

extension Collection where Element == USBDevice {
    /// The devices someone may mean by `text`: a device's number, its `vendor:product`, its serial number
    /// or its name, with or without its maker's in front. A number names one device; the rest can fit
    /// several of the same make.
    public func matching(_ text: String) -> [USBDevice] {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return [] }
        if let id = UInt64(wanted), let device = first(where: { $0.id == id }) {
            return [device]
        }
        return filter { device in
            let name = device.name.lowercased()
            return device.identifier == wanted || name == wanted || device.serialNumber?.lowercased() == wanted
                || device.manufacturer.map { "\($0.lowercased()) \(name)" } == wanted
        }
    }
}

extension USBConfiguration.DeviceRule {
    /// The rule that takes every device of this make.
    public init(device: USBDevice) {
        self.init(vendorID: device.vendorID, productID: device.productID, name: device.name)
    }

    public func matches(_ device: USBDevice) -> Bool {
        vendorID == device.vendorID && productID == device.productID
    }
}

extension USBConfiguration {
    /// Whether the machine takes `device` by itself whenever both are there.
    public func connectsAutomatically(_ device: USBDevice) -> Bool {
        autoConnect.contains { $0.matches(device) }
    }

    /// Adds or removes the rule for devices of this make.
    public mutating func setConnectsAutomatically(_ isOn: Bool, for device: USBDevice) {
        autoConnect.removeAll { $0.matches(device) }
        if isOn {
            autoConnect.append(DeviceRule(device: device))
        }
    }
}
