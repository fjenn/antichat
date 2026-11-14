// M5.T07 (R-292 AC1; K-014 / Q-009 (a), D-019): when the plan card offers the Sound chip (`video.sound`) and which model
// a "Sound on" job runs on. The chip shows only when one of the tier's video models has the catalog capability `audio`
// (today `vid-ltx`, T3+) AND the chat is Normal: LTX's licence is Normal only, so Evil chats never see the chip and
// their video runs on `vid-5b` (silent). Silent models hide the chip.
import Foundation

public enum VideoSound {
    public static let capability = "audio"

    /// One video model the tier offers: its catalog key and capabilities.
    public struct Model: Sendable, Equatable {
        public var key: String
        public var capabilities: [String]
        public init(key: String, capabilities: [String]) {
            self.key = key
            self.capabilities = capabilities
        }
        public var hasSound: Bool { capabilities.contains(VideoSound.capability) }
    }

    /// True when the plan card shows the Sound chip.
    public static func chipVisible(models: [Model], isEvil: Bool) -> Bool {
        !isEvil && models.contains(where: \.hasSound)
    }

    /// The model a text-to-video job runs on: the sound model when Sound is on (and allowed), else the first silent one.
    public static func model(for sound: Bool, models: [Model], isEvil: Bool) -> Model? {
        if sound, chipVisible(models: models, isEvil: isEvil) { return models.first(where: \.hasSound) }
        return models.first { !$0.hasSound } ?? (isEvil ? nil : models.first)
    }
}
