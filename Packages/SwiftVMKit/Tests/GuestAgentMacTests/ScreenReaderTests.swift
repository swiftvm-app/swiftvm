import ApplicationServices
import Foundation
import Testing
@testable import GuestAgentMac

@Suite struct ScreenReaderTests {
    @Test func failedNativeReadsMakeTheTreeIncomplete() throws {
        for failedProperty in [nil, "AXChildren", "AXIdentifier"] {
            var reader = ScreenReader(scale: 1, everything: false)
            var calls = 0
            reader.readAttributes = { _, attributes in
                calls += 1
                if failedProperty == nil, calls > 1 { return nil }
                var error = AXError.cannotComplete
                return attributes.map { name -> Any in
                    if name == failedProperty { return AXValueCreate(.axError, &error)! as Any }
                    switch name {
                    case "AXRole": return calls == 1 ? "AXApplication" : "AXButton"
                    case "AXTitle": return "Sample"
                    case "AXChildren" where calls == 1: return [AXUIElementCreateApplication(.max)]
                    default: return NSNull()
                    }
                }
            }
            let parts = reader.describe(application: .max, named: "Sample", depth: 3)
            let json = try JSONEncoder().encode(ScreenTree(applications: parts, truncated: reader.isTruncated))
            let tree = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
            #expect(tree["truncated"] as? Bool == true)
        }
    }

    @Test func unsupportedOptionalAttributesAreNotFailedReads() {
        var reader = ScreenReader(scale: 1, everything: false)
        var calls = 0
        reader.readAttributes = { _, attributes in
            calls += 1
            var error = AXError.attributeUnsupported
            return attributes.map { name -> Any in
                switch name {
                case "AXRole": return calls == 1 ? "AXApplication" : "AXButton"
                case "AXTitle": return "Sample"
                case "AXChildren" where calls == 1: return [AXUIElementCreateApplication(.max)]
                default: return AXValueCreate(.axError, &error)! as Any
                }
            }
        }
        let parts = reader.describe(application: .max, named: "Sample", depth: 3)
        #expect(parts.first?.children?.first?.name == "Sample")
        #expect(parts.first?.children?.first?.identifier == nil)
        #expect(!reader.isTruncated)
    }
}
