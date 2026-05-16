import DDCMirrorCore
import Foundation

do {
    let configuration = try Configuration.parse(
        arguments: CommandLine.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    let reader = try DisplayServicesBrightnessReader()
    let backend = try BackendFactory.makeBackend(for: configuration)
    let service = MirrorService(configuration: configuration, reader: reader, backend: backend)
    try service.run()
} catch ConfigurationError.helpRequested {
    print(Configuration.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("ddc-mirror: \(error)\n".utf8))
    exit(1)
}
