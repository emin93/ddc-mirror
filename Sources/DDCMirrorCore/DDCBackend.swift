import Foundation

public protocol DDCBackend {
    var name: String { get }
    func setBrightness(percent: Int) throws
}

public struct BackendFactory {
    public static func makeBackend(for configuration: Configuration) throws -> any DDCBackend {
        let locator = CommandLocator()

        switch configuration.backend {
        case .automatic:
            if let path = locator.find("m1ddc") {
                return CommandDDCBackend(kind: .m1ddc, executable: path, targets: configuration.displayTargets)
            }
            if let path = locator.find("ddcctl") {
                return CommandDDCBackend(kind: .ddcctl, executable: path, targets: configuration.displayTargets)
            }
            throw DDCBackendError.backendNotFound
        case .m1ddc:
            guard let path = locator.find("m1ddc") else {
                throw DDCBackendError.executableNotFound("m1ddc")
            }
            return CommandDDCBackend(kind: .m1ddc, executable: path, targets: configuration.displayTargets)
        case .ddcctl:
            guard let path = locator.find("ddcctl") else {
                throw DDCBackendError.executableNotFound("ddcctl")
            }
            return CommandDDCBackend(kind: .ddcctl, executable: path, targets: configuration.displayTargets)
        case .print:
            return PrintDDCBackend()
        }
    }
}

public enum DDCBackendError: Error, CustomStringConvertible {
    case backendNotFound
    case executableNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)

    public var description: String {
        switch self {
        case .backendNotFound:
            return "no DDC backend found; install m1ddc or ddcctl, or run with --backend print"
        case .executableNotFound(let name):
            return "\(name) was not found in PATH or common Homebrew locations"
        case .commandFailed(let command, let status, let output):
            return "\(command) failed with exit status \(status): \(output)"
        }
    }
}

public struct CommandDDCBackend: DDCBackend {
    public enum Kind: String {
        case m1ddc
        case ddcctl
    }

    public let kind: Kind
    public let executable: String
    public let targets: [String]

    public var name: String { kind.rawValue }

    public init(kind: Kind, executable: String, targets: [String] = []) {
        self.kind = kind
        self.executable = executable
        self.targets = targets
    }

    public func setBrightness(percent: Int) throws {
        let bounded = max(0, min(100, percent))
        let commands = arguments(for: bounded)

        for arguments in commands {
            let result = try ProcessRunner.run(executable, arguments: arguments)
            guard result.status == 0 else {
                let command = ([executable] + arguments).joined(separator: " ")
                throw DDCBackendError.commandFailed(
                    command: command,
                    status: result.status,
                    output: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }
    }

    private func arguments(for percent: Int) -> [[String]] {
        let value = String(percent)

        switch kind {
        case .m1ddc:
            guard !targets.isEmpty else {
                return [["set", "luminance", value]]
            }
            return targets.map { ["display", $0, "set", "luminance", value] }
        case .ddcctl:
            guard !targets.isEmpty else {
                return [["-b", value]]
            }
            return targets.map { ["-d", $0, "-b", value] }
        }
    }
}

public struct PrintDDCBackend: DDCBackend {
    public let name = "print"

    public init() {}

    public func setBrightness(percent: Int) {
        print("brightness=\(max(0, min(100, percent)))")
    }
}
