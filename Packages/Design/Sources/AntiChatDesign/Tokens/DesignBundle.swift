// Hand-written support for the generated token files (M1.T03). Not generated.
import AntiChatFoundation
import AppKit
import Synchronization
import SwiftUI

/// Runtime facts the generated colour tokens need.
public enum DesignBundle {
    /// The resource bundle holding `Tokens.xcassets`.
    public static var bundle: Bundle { .module }

    /// tokens.md §1.2 `accent`: the system accent colour, except when the user picked "Multicolor" (no
    /// `AppleAccentColor` default), where the AntiChat brand blue is used. Snapshot tests set
    /// `forceBrandAccent` so references do not depend on the machine's accent setting.
    public static var usesSystemAccent: Bool {
        if forceBrandAccent { return false }
        return AppDefaults.standard.object(forKey: "AppleAccentColor") != nil
    }

    public static var forceBrandAccent: Bool {
        get { brandAccent.withLock { $0 } }
        set { brandAccent.withLock { $0 = newValue } }
    }

    private static let brandAccent = Mutex(false)
}

public extension Color {
    /// A colour from a 0xRRGGBBAA literal (generated gradients and shadows).
    init(tokenHex rgba: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            opacity: Double(rgba & 0xFF) / 255
        )
    }
}

public extension View {
    /// Applies a tokens.md §4 shadow.
    func tokenShadow(_ s: ShadowToken) -> some View {
        shadow(color: s.color, radius: s.blur / 2, x: 0, y: s.y)
    }
}
