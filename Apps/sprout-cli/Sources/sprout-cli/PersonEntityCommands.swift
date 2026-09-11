import Foundation

/// Entry points for the human's entity. Scaffold owner keys and bootstrap
/// contracts are intentionally not read, signed or promoted by these commands.
enum PersonEntityCommands {
    enum Failure: Error { case invalidArguments, helperNotInstalled, helperFailed(Int32) }

    static func connect(_ arguments: [String]) throws {
        guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--place") else { throw Failure.invalidArguments }
        let place = arguments.last ?? "app"
        let address: String
        switch place {
        case "app": address = "haven://link-devices"
        case "haven": address = "https://haven.digipomps.org/link"
        case "staging": address = "https://staging.haven.digipomps.org/link"
        default: throw Failure.invalidArguments
        }
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [address]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.helperFailed(process.terminationStatus) }
        print("Åpnet kobling av dine entiteter. Kontroller begge entiteter og godkjenn i HAVEN. Sprout har ikke opprettet en kobling.")
        #else
        print("Åpne på telefonen eller datamaskinen: \(address)")
        #endif
    }

    static func nearby(_ arguments: [String]) throws {
        #if os(macOS)
        // Installed next to sprout; an explicit local override supports candidate tests.
        let helper = ProcessInfo.processInfo.environment["SPROUT_NEARBY_HELPER"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("haven-nearby")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure.helperNotInstalled }
        guard let verb = arguments.first, ["browse", "inspect", "advertise", "--help"].contains(verb) else { throw Failure.invalidArguments }
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.helperFailed(process.terminationStatus) }
        #else
        throw Failure.helperNotInstalled
        #endif
    }
}
