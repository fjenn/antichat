// The names of generated pictures and clips: made from the prompt, unique in a chat, read back for old files.
import Foundation
import Testing
@testable import AntiChatStorage

@Suite struct StoredFileNamesTests {
    @Test func nameFromPrompt() {
        #expect(StoredFileNames.base(prompt: "a cosy reading nook, watercolour style") == "A cosy reading nook")
        #expect(StoredFileNames.base(prompt: "  \"red fox\" in a snowy forest at sunrise with long golden light rays") == "Red fox")
        #expect(StoredFileNames.base(prompt: "a red fox in a snowy forest at sunrise with long golden light").count <= 40)
        #expect(StoredFileNames.base(prompt: "a small sailboat on a calm lake at sunrise") == "A small sailboat on a calm lake")
        #expect(StoredFileNames.base(prompt: "…") == "")
    }

    @Test func uniqueInAChat() {
        let taken: Set<String> = ["Cosy reading nook.png", "cosy reading nook 2.PNG"]
        #expect(StoredFileNames.unique(base: "Cosy reading nook", ext: "png", taken: taken) == "Cosy reading nook 3.png")
        #expect(StoredFileNames.unique(base: "Campfire", ext: "mp4", taken: taken) == "Campfire.mp4")
    }

    @Test func nameOfAStoredVersion() {
        #expect(StoredFileNames.name(title: "Fox.png", specJSON: #"{"filename":"Fox at night.png","prompt":"x"}"#) == "Fox at night.png")
        #expect(StoredFileNames.name(title: "image.png", specJSON: #"{"prompt":"a lighthouse at dusk, oil paint"}"#) == "A lighthouse at dusk.png")
        #expect(StoredFileNames.name(title: "video.mp4", specJSON: nil) == "video.mp4")
        #expect(StoredFileNames.name(title: "Budget.xlsx", specJSON: #"{"prompt":"ignored"}"#) == "Budget.xlsx")
    }
}
