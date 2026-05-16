import Foundation

public enum BackendPreference: String, Sendable {
    case automatic = "auto"
    case m1ddc
    case ddcctl
    case betterdisplay
    case print
}

public struct Configuration: Sendable {
    public let backend: BackendPreference
    public let displayTargets: [String]
    public let interval: TimeInterval
    public let minimumDelta: Float
    public let mapper: BrightnessMapper
    public let once: Bool
    public let verbose: Bool

    public init(
        backend: BackendPreference = .automatic,
        displayTargets: [String] = [],
        interval: TimeInterval = 0.5,
        minimumDelta: Float = 0.01,
        mapper: BrightnessMapper = try! BrightnessMapper(),
        once: Bool = false,
        verbose: Bool = false
    ) {
        self.backend = backend
        self.displayTargets = displayTargets
        self.interval = interval
        self.minimumDelta = minimumDelta
        self.mapper = mapper
        self.once = once
        self.verbose = verbose
    }

    public static func parse(arguments: [String], environment: [String: String]) throws -> Configuration {
        var backend = BackendPreference(rawValue: environment["DDC_MIRROR_BACKEND"] ?? "") ?? .automatic
        var targets = parseTargets(environment["DDC_MIRROR_DISPLAYS"])
        var interval = try parseDouble(environment["DDC_MIRROR_INTERVAL"], name: "DDC_MIRROR_INTERVAL") ?? 0.5
        var minimumDelta = try parseFloat(environment["DDC_MIRROR_MIN_DELTA"], name: "DDC_MIRROR_MIN_DELTA") ?? 0.01
        var minimum = try parseInt(environment["DDC_MIRROR_MIN"], name: "DDC_MIRROR_MIN") ?? 0
        var maximum = try parseInt(environment["DDC_MIRROR_MAX"], name: "DDC_MIRROR_MAX") ?? 100
        var once = false
        var verbose = environment["DDC_MIRROR_VERBOSE"] == "1"

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--backend":
                index += 1
                backend = try parseBackend(value(at: index, in: arguments, for: argument))
            case "--display":
                index += 1
                targets.append(try value(at: index, in: arguments, for: argument))
            case "--displays":
                index += 1
                targets = parseTargets(try value(at: index, in: arguments, for: argument))
            case "--interval":
                index += 1
                interval = try parseRequiredDouble(value(at: index, in: arguments, for: argument), name: argument)
            case "--min-delta":
                index += 1
                minimumDelta = try parseRequiredFloat(value(at: index, in: arguments, for: argument), name: argument)
            case "--min":
                index += 1
                minimum = try parseRequiredInt(value(at: index, in: arguments, for: argument), name: argument)
            case "--max":
                index += 1
                maximum = try parseRequiredInt(value(at: index, in: arguments, for: argument), name: argument)
            case "--once":
                once = true
            case "--verbose":
                verbose = true
            case "--help", "-h":
                throw ConfigurationError.helpRequested
            default:
                throw ConfigurationError.invalidValue("unknown argument: \(argument)")
            }
            index += 1
        }

        guard interval > 0 else {
            throw ConfigurationError.invalidValue("interval must be greater than 0")
        }
        guard minimumDelta >= 0 else {
            throw ConfigurationError.invalidValue("minimum delta must be greater than or equal to 0")
        }

        return Configuration(
            backend: backend,
            displayTargets: targets,
            interval: interval,
            minimumDelta: minimumDelta,
            mapper: try BrightnessMapper(minimumPercent: minimum, maximumPercent: maximum),
            once: once,
            verbose: verbose
        )
    }

    public static let usage = """
    Usage: ddc-mirror [options]

    Mirrors the active built-in display brightness to external DDC/CI monitors.

    Options:
      --backend auto|m1ddc|ddcctl|betterdisplay|print  DDC backend to use (default: auto)
      --display ID                       Target display ID for the backend; repeatable
      --displays ID,ID                   Comma-separated target display IDs
      --interval SECONDS                 Poll interval (default: 0.5)
      --min-delta FRACTION               Minimum internal brightness change to sync (default: 0.01)
      --min PERCENT                      External brightness at internal 0.0 (default: 0)
      --max PERCENT                      External brightness at internal 1.0 (default: 100)
      --once                             Sync once and exit
      --verbose                          Log sync decisions
      --help                             Show this help

    Environment variables mirror the option names:
      DDC_MIRROR_BACKEND, DDC_MIRROR_DISPLAYS, DDC_MIRROR_INTERVAL,
      DDC_MIRROR_MIN_DELTA, DDC_MIRROR_MIN, DDC_MIRROR_MAX, DDC_MIRROR_VERBOSE
    """

    private static func value(at index: Int, in arguments: [String], for option: String) throws -> String {
        guard index < arguments.count else {
            throw ConfigurationError.invalidValue("missing value for \(option)")
        }
        return arguments[index]
    }

    private static func parseBackend(_ value: String) throws -> BackendPreference {
        guard let backend = BackendPreference(rawValue: value) else {
            throw ConfigurationError.invalidValue("invalid backend: \(value)")
        }
        return backend
    }

    private static func parseTargets(_ raw: String?) -> [String] {
        raw?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func parseDouble(_ raw: String?, name: String) throws -> Double? {
        guard let raw else { return nil }
        return try parseRequiredDouble(raw, name: name)
    }

    private static func parseFloat(_ raw: String?, name: String) throws -> Float? {
        guard let raw else { return nil }
        return try parseRequiredFloat(raw, name: name)
    }

    private static func parseInt(_ raw: String?, name: String) throws -> Int? {
        guard let raw else { return nil }
        return try parseRequiredInt(raw, name: name)
    }

    private static func parseRequiredDouble(_ raw: String, name: String) throws -> Double {
        guard let value = Double(raw) else {
            throw ConfigurationError.invalidValue("\(name) must be a number")
        }
        return value
    }

    private static func parseRequiredFloat(_ raw: String, name: String) throws -> Float {
        guard let value = Float(raw) else {
            throw ConfigurationError.invalidValue("\(name) must be a number")
        }
        return value
    }

    private static func parseRequiredInt(_ raw: String, name: String) throws -> Int {
        guard let value = Int(raw) else {
            throw ConfigurationError.invalidValue("\(name) must be an integer")
        }
        return value
    }
}

public enum ConfigurationError: Error, CustomStringConvertible, Equatable {
    case helpRequested
    case invalidValue(String)

    public var description: String {
        switch self {
        case .helpRequested:
            return Configuration.usage
        case .invalidValue(let message):
            return message
        }
    }
}
