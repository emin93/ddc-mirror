import CoreGraphics
import Darwin
import Foundation

public protocol BrightnessReader {
    func readBuiltInBrightness() throws -> Float
}

public final class DisplayServicesBrightnessReader: BrightnessReader {
    private typealias DisplayServicesGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let getBrightness: DisplayServicesGetBrightness

    public init() throws {
        let candidatePaths = [
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            "/System/Library/LoginPlugins/DisplayServices.loginPlugin/Contents/MacOS/DisplayServices",
        ]

        var loadedHandle: UnsafeMutableRawPointer?
        for path in candidatePaths {
            loadedHandle = dlopen(path, RTLD_NOW)
            if loadedHandle != nil {
                break
            }
        }

        guard let handle = loadedHandle else {
            throw BrightnessReaderError.displayServicesUnavailable(String(cString: dlerror()))
        }

        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            throw BrightnessReaderError.displayServicesUnavailable("DisplayServicesGetBrightness was not found")
        }

        self.handle = handle
        self.getBrightness = unsafeBitCast(symbol, to: DisplayServicesGetBrightness.self)
    }

    deinit {
        dlclose(handle)
    }

    public func readBuiltInBrightness() throws -> Float {
        var count: UInt32 = 0
        var error = CGGetOnlineDisplayList(0, nil, &count)
        guard error == .success else {
            throw BrightnessReaderError.displayListUnavailable(error)
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        error = CGGetOnlineDisplayList(count, &displays, &count)
        guard error == .success else {
            throw BrightnessReaderError.displayListUnavailable(error)
        }

        for display in displays where CGDisplayIsBuiltin(display) != 0 && CGDisplayIsActive(display) != 0 {
            var brightness: Float = 0
            let result = getBrightness(display, &brightness)
            if result == 0 {
                return max(0, min(1, brightness))
            }
        }

        throw BrightnessReaderError.noActiveBuiltInDisplay
    }
}

public enum BrightnessReaderError: Error, CustomStringConvertible {
    case displayServicesUnavailable(String)
    case displayListUnavailable(CGError)
    case noActiveBuiltInDisplay

    public var description: String {
        switch self {
        case .displayServicesUnavailable(let message):
            return "DisplayServices unavailable: \(message)"
        case .displayListUnavailable(let error):
            return "could not list online displays: \(error)"
        case .noActiveBuiltInDisplay:
            return "no active built-in display found; ddc-mirror requires the built-in display to be open and active"
        }
    }
}
