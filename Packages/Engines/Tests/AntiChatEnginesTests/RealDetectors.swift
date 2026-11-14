// Test support (M5.T04/T06): the opt-in real-detector legs of the media-runner suites.
import AntiChatEngineProtocol
import Foundation
@testable import AntiChatEngines

/// The real ChildSafetyCheck detectors for the opt-in legs (`CSC_REAL_DETECTORS=1`, the dev detector files), with a
/// persistent compiled-model cache so a run compiles once.
enum RealDetectors {
    static var manifest: SafetyManifest? {
        ProcessInfo.processInfo.environment["CSC_REAL_DETECTORS"] == "1" ? try? SafetyPrepareTests.devManifest() : nil
    }
    static let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/AntiChat-Dev/csc-engine-tests")
    static func runner() -> MediaJobRunner { MediaJobRunner(releaseAfter: .milliseconds(50), cacheDirectory: cache) }
}
