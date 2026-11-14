// M3.T01 (P-media-05, D-11; InjectionCoverageTests hook for argmax-oss-swift): the only way AntiChat builds a
// WhisperKit configuration. The model and its tokenizer load from the `stt-multi` install folder in the model
// store; `download: false` and a local `tokenizerFolder` keep WhisperKit's Downloader / HubApi sessions unused,
// so no byte leaves the Mac outside NetworkGate. M3.T05 (WhisperKitBackend) is the first caller.
import Foundation
import WhisperKit

public enum WhisperKitLocal {
    public static func config(modelFolder: URL, tokenizerFolder: URL? = nil) -> WhisperKitConfig {
        WhisperKitConfig(modelFolder: modelFolder.path, tokenizerFolder: tokenizerFolder ?? modelFolder, verbose: false,
                         prewarm: false, load: true, download: false)
    }
}
