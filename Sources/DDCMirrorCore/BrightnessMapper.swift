import Foundation

public struct BrightnessMapper: Sendable {
    public let minimumPercent: Int
    public let maximumPercent: Int

    public init(minimumPercent: Int = 0, maximumPercent: Int = 100) throws {
        guard (0...100).contains(minimumPercent) else {
            throw ConfigurationError.invalidValue("minimum brightness must be between 0 and 100")
        }
        guard (0...100).contains(maximumPercent) else {
            throw ConfigurationError.invalidValue("maximum brightness must be between 0 and 100")
        }
        guard minimumPercent <= maximumPercent else {
            throw ConfigurationError.invalidValue("minimum brightness cannot exceed maximum brightness")
        }

        self.minimumPercent = minimumPercent
        self.maximumPercent = maximumPercent
    }

    public func percent(forInternalBrightness brightness: Float) -> Int {
        let clamped = max(0, min(1, brightness))
        let span = Float(maximumPercent - minimumPercent)
        return Int((Float(minimumPercent) + (clamped * span)).rounded())
    }
}
