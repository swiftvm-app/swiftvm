import Foundation
import Testing
import VMControl
@testable import SwiftVMCLI

@Suite struct FixedDisplayArgumentsTests {
    @Test func fixedModeAndPhysicalGeometrySurviveTheWire() throws {
        let request = try FixedDisplay.request(["Box", "2560", "1664", "220", "--fixed"])
        #expect(request.command == .displayFixed && request.machine == "Box")
        #expect(request.display == .init(widthInPixels: 2560, heightInPixels: 1664, pixelsPerInch: 220))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func invalidDimensionsAndImplicitOrUnknownModesRefuse() {
        for arguments in [
            ["Box", "2560", "1664", "220"], ["Box", "2560", "1664", "220", "--auto"],
            ["Box", "0", "1664", "220", "--fixed"], ["Box", "2560", "-1", "220", "--fixed"],
            ["Box", "2560", "1664", "0", "--fixed"], ["Box", "2560", "1664", "220.5", "--fixed"],
            ["Box", "999999999999999999999999999", "1664", "220", "--fixed"],
            ["Box", "2560", "1664", "220", "--fixed", "--fixed"],
        ] {
            #expect(throws: FixedDisplay.ParseError.self) { try FixedDisplay.request(arguments) }
        }
    }
}
