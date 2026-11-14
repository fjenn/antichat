// Hand-written behaviour for the generated Motion.swift (M1.T03 step 3; tokens.md §5, NFR-A4). Not generated.
import SwiftUI

/// One tokens.md §5 motion token. Values live in the generated `Motion.swift`.
public struct MotionToken: Sendable, Hashable {
    public enum Curve: Sendable, Hashable {
        /// No animation curve (instant, clocks, delays, audio-driven).
        case none
        case easeOut, easeInOut, linear
        /// `.smooth` (spring, response 0.3, damping 1).
        case smooth
    }

    /// What the token's Reduce Motion column asks for.
    public enum ReduceMotion: Sendable, Hashable {
        /// Same as with motion on.
        case same
        /// Keep only an opacity change (no scale or movement).
        case opacityOnly
        /// Cross-fade of the given seconds instead of the movement (0 = swap).
        case crossFade(Double)
        /// No animation at all.
        case none
    }

    public let name: String
    /// Seconds.
    public let duration: Double
    public let curve: Curve
    public let reduceMotion: ReduceMotion

    /// The token's animation, or `nil` when it has none or when Reduce Motion is on (M1.T03 step 3).
    /// Callers that cross-fade under Reduce Motion use `reducedCrossFade` for the opacity change.
    public func animation(reduceMotion reduce: Bool) -> Animation? {
        if reduce, reduceMotion != .same { return nil }
        return baseAnimation
    }

    /// Under Reduce Motion: the opacity-only animation the token allows (`opacityOnly` keeps the duration,
    /// `crossFade(s)` uses `s`), else `nil`.
    public var reducedCrossFade: Animation? {
        switch reduceMotion {
        case .opacityOnly: duration > 0 ? .easeOut(duration: duration) : nil
        case .crossFade(let s): s > 0 ? .linear(duration: s) : nil
        case .same: baseAnimation
        case .none: nil
        }
    }

    private var baseAnimation: Animation? {
        guard duration > 0 else { return nil }
        switch curve {
        case .none: return nil
        case .easeOut: return .easeOut(duration: duration)
        case .easeInOut: return .easeInOut(duration: duration)
        case .linear: return .linear(duration: duration)
        case .smooth: return .smooth(duration: duration, extraBounce: 0)
        }
    }
}

public extension EnvironmentValues {
    /// R-101 "Reduce motion" override from Settings → Appearance (M1.T23 sets it); `nil` follows the system.
    @Entry var reduceMotionOverride: Bool? = nil
}

/// The effective Reduce Motion flag: the R-101 override when set, else the system setting.
@propertyWrapper
public struct EffectiveReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var override
    public init() {}
    public var wrappedValue: Bool { override ?? system }
}

public extension View {
    /// `withAnimation`-free token animation on `value` changes, honouring Reduce Motion.
    func tokenAnimation<V: Equatable>(_ token: MotionToken, value: V) -> some View {
        modifier(TokenAnimationModifier(token: token, value: value))
    }
}

private struct TokenAnimationModifier<V: Equatable>: ViewModifier {
    let token: MotionToken
    let value: V
    @EffectiveReduceMotion private var reduce
    func body(content: Content) -> some View {
        content.animation(token.animation(reduceMotion: reduce), value: value)
    }
}
