import DDCMirrorCore
import Foundation

do {
    let processEnvironment = ProcessInfo.processInfo.environment
    var environment = ConfigurationFile.load(processEnvironment: processEnvironment)
    environment.merge(processEnvironment) { _, processValue in processValue }

    let configuration = try Configuration.parse(
        arguments: CommandLine.arguments,
        environment: environment
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
