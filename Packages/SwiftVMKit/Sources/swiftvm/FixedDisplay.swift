import VMControl

enum FixedDisplay {
    static let usage = "Usage: swiftvm display <machine> <pixel-width> <pixel-height> <ppi> --fixed"
    enum ParseError: Error { case invalid }

    static func request(_ arguments: [String]) throws -> ControlRequest {
        guard arguments.count == 5, !arguments[0].isEmpty, arguments[4] == "--fixed",
              let width = Int(arguments[1]), width > 0, let height = Int(arguments[2]), height > 0,
              let ppi = Int(arguments[3]), ppi > 0 else { throw ParseError.invalid }
        return ControlRequest(
            command: .displayFixed, machine: arguments[0],
            display: .init(widthInPixels: width, heightInPixels: height, pixelsPerInch: ppi)
        )
    }
}
