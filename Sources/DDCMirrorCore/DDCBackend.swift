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
            var backends: [any DDCBackend] = []
            if let path = locator.find("m1ddc") {
                backends.append(CommandDDCBackend(kind: .m1ddc, executable: path, targets: configuration.displayTargets))
            }
            if let path = locator.find("ddcctl") {
                backends.append(CommandDDCBackend(kind: .ddcctl, executable: path, targets: configuration.displayTargets))
            }
            if let path = locator.find("betterdisplaycli") {
                backends.append(CommandDDCBackend(kind: .betterdisplay, executable: path, targets: configuration.displayTargets))
            }
            guard !backends.isEmpty else {
                throw DDCBackendError.backendNotFound
            }
            return FallbackDDCBackend(backends: backends)
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
        case .betterdisplay:
            guard let path = locator.find("betterdisplaycli") else {
                throw DDCBackendError.executableNotFound("betterdisplaycli")
            }
            return CommandDDCBackend(kind: .betterdisplay, executable: path, targets: configuration.displayTargets)
        case .print:
            return PrintDDCBackend()
        }
    }
}

public enum DDCBackendError: Error, CustomStringConvertible {
    case backendNotFound
    case executableNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)
    case allBackendsFailed([String])

    public var description: String {
        switch self {
        case .backendNotFound:
            return "no DDC backend found; install m1ddc, ddcctl, or BetterDisplay, or run with --backend print"
        case .executableNotFound(let name):
            return "\(name) was not found in PATH or common Homebrew locations"
        case .commandFailed(let command, let status, let output):
            return "\(command) failed with exit status \(status): \(output)"
        case .allBackendsFailed(let failures):
            return "all DDC backends failed: \(failures.joined(separator: "; "))"
        }
    }
}

public struct CommandDDCBackend: DDCBackend {
    public enum Kind: String {
        case m1ddc
        case ddcctl
        case betterdisplay
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
        case .betterdisplay:
            let brightness = "--hardwareBrightness=\(value)%"
            guard !targets.isEmpty else {
                return [["set", brightness]]
            }
            return targets.map { target in
                if target.contains("-") {
                    return ["set", "--UUID=\(target)", brightness]
                }
                return ["set", "--nameLike=\(target)", brightness]
            }
        }
    }
}

public final class FallbackDDCBackend: DDCBackend {
    private let backends: [any DDCBackend]
    private var selectedBackend: (any DDCBackend)?

    public var name: String {
        if let selectedBackend {
            return selectedBackend.name
        }
        return backends.map(\.name).joined(separator: ",")
    }

    public init(backends: [any DDCBackend]) {
        self.backends = backends
    }

    public func setBrightness(percent: Int) throws {
        if let selectedBackend {
            try selectedBackend.setBrightness(percent: percent)
            return
        }

        var failures: [String] = []
        for backend in backends {
            do {
                try backend.setBrightness(percent: percent)
                selectedBackend = backend
                return
            } catch {
                failures.append("\(backend.name): \(error)")
            }
        }

        throw DDCBackendError.allBackendsFailed(failures)
    }
}

public struct PrintDDCBackend: DDCBackend {
    public let name = "print"

    public init() {}

    public func setBrightness(percent: Int) {
        print("brightness=\(max(0, min(100, percent)))")
    }
}
