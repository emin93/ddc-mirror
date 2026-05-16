import Foundation

public enum ConfigurationFile {
    public static func load(processEnvironment: [String: String]) -> [String: String] {
        let path = processEnvironment["DDC_MIRROR_CONFIG"]
            ?? defaultPath(processEnvironment: processEnvironment)

        guard FileManager.default.isReadableFile(atPath: path),
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }

        return parse(contents)
    }

    public static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]

        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=") else {
                continue
            }

            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                continue
            }

            values[key] = unquote(rawValue)
        }

        return values
    }

    private static func defaultPath(processEnvironment: [String: String]) -> String {
        let home = processEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/ddc-mirror/config"
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else {
            return value
        }

        if value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }

        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}
