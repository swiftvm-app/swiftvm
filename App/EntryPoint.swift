import SwiftUI

/// Where the program starts: as the app, unless it was started outside of one.
@main
enum EntryPoint {
    static func main() {
        DevelopmentLauncher.handOverUnlessInAnApp()
        SwiftVMApp.main()
    }
}
