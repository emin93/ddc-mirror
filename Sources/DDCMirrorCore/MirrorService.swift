import Foundation

public final class MirrorService {
    private let configuration: Configuration
    private let reader: any BrightnessReader
    private let backend: any DDCBackend
    private var lastSyncedBrightness: Float?

    public init(
        configuration: Configuration,
        reader: any BrightnessReader,
        backend: any DDCBackend
    ) {
        self.configuration = configuration
        self.reader = reader
        self.backend = backend
    }

    public func run() throws {
        repeat {
            try syncIfNeeded()

            if configuration.once {
                return
            }

            Thread.sleep(forTimeInterval: configuration.interval)
        } while true
    }

    public func syncIfNeeded() throws {
        let brightness = try reader.readBuiltInBrightness()

        if let lastSyncedBrightness, abs(brightness - lastSyncedBrightness) < configuration.minimumDelta {
            if configuration.verbose {
                log("unchanged internal brightness \(format(brightness)); skipping")
            }
            return
        }

        let percent = configuration.mapper.percent(forInternalBrightness: brightness)
        try backend.setBrightness(percent: percent)
        lastSyncedBrightness = brightness

        if configuration.verbose {
            log("synced internal brightness \(format(brightness)) to \(percent)% using \(backend.name)")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[ddc-mirror] \(message)\n".utf8))
    }

    private func format(_ brightness: Float) -> String {
        String(format: "%.3f", brightness)
    }
}
