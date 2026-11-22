import Testing
@testable import VZEngine

struct VirtualizationProcessTests {
    /// The framework's process for one machine holds files of that machine's bundle, and of no other's,
    /// even one whose name starts the same.
    @Test func tellsAMachinesProcessByTheFilesOfItsBundle() {
        let bundle = "/Users/username/Machines/Ubuntu.swiftvm"
        #expect(VirtualizationProcess.holdsFile(in: bundle, openPaths: ["/dev/null", "\(bundle)/efi-vars.fd"]))
        #expect(VirtualizationProcess.holdsFile(in: bundle + "/", openPaths: ["\(bundle)/aux.img"]))
        #expect(!VirtualizationProcess.holdsFile(in: bundle, openPaths: ["/Users/username/Machines/Ubuntu.swiftvm 2/efi-vars.fd"]))
        #expect(!VirtualizationProcess.holdsFile(in: bundle, openPaths: [bundle, "/dev/null"]))
    }
}
