import Foundation

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
}

public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output)
    }
}

public struct CommandLocator {
    private let fileManager: FileManager
    private let environment: [String: String]

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
    }

    public func find(_ executable: String) -> String? {
        for directory in searchPaths() {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func searchPaths() -> [String] {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return pathDirectories + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/m1ddc/bin",
            "/opt/homebrew/opt/ddcctl/bin",
            "/usr/local/opt/ddcctl/bin",
        ]
    }
}
