// D-11 for the voice stack (M0.T05 step 1): FluidAudio never touches the network in the helper, and the
// helper's environment carries no Hugging Face credentials or endpoint/registry overrides.
import Darwin
import FluidAudio

public enum VoiceEnvironment {
    public static let scrubbed = ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "HF_ENDPOINT", "REGISTRY_URL"]

    public static func lockDown() {
        ModelHub.offlineMode = true
        for k in scrubbed { unsetenv(k) }
    }
}
