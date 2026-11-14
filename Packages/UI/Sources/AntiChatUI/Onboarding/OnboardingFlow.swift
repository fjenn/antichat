// M2.T18 step 1 (S-00…S-04 chrome; screens.md "Onboarding"): the onboarding root. Always dark. Full-bleed dreamworld
// art (full colour + `onb.scrim.step1` on step 1, `onb.art.desaturate` on steps 2 and 4), the wordmark top-left and
// `onb.brand.tag` top-right at the 60 pt margin, `onb.nav.back` bottom-left (hidden on step 1; step 4 has it too), `onb.nav.step`
// bottom-right and the decorative pill handle bottom-centre (hidden from VoiceOver).
// Keyboard (NFR-A3): Return = the step's primary CTA, Esc / ⌘[ = Back, ←/→ between pack cards, Space toggles.
import AntiChatDesign
import AppKit
import CoreImage
import SwiftUI

public struct OnboardingFlow: View {
    @Bindable var model: OnboardingModel
    /// Step 3 (Evil Mode) content; M2.T19 supplies it. nil = a plain pass-through.
    var evilStep: AnyView?
    /// Step 4's live install (M2.T20).
    var status: SetupStatus
    /// The step whose crossfade has finished (nil while one runs). DEBUG builds expose it to UI tests on the step
    /// counter, so the accessibility audit measures a step at rest, not a half-faded frame (M9.T03).
    @State private var settledStep: OnboardingModel.Step?
    @State private var fadingTo: OnboardingModel.Step?
    /// Which settle clock is current: a restarted clock (window became key, step 1's entrance began) makes an earlier
    /// one's completion stale. Before, the first 0.8 s clock still set the marker while the restarted entrance was
    /// running, and the audit measured "No lectures." half faded in (RC e8fe19986, "Contrast failed").
    @State private var settleClock = 0

    /// (Re)starts the settle clock for `step`: the marker comes up `seconds` later unless a newer clock started.
    private func settle(_ step: OnboardingModel.Step, after seconds: Double) {
        settledStep = nil
        settleClock += 1
        let clock = settleClock
        withAnimation(.linear(duration: seconds)) { fadingTo = fadingTo == step ? nil : step } completion: {
            if model.step == step, settleClock == clock { settledStep = step }
        }
    }

    public init(model: OnboardingModel, evilStep: AnyView? = nil, status: SetupStatus? = nil) {
        self.model = model
        self.evilStep = evilStep
        self.status = status ?? SetupLaunch.status
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                OnboardingBackground(step: model.step)
                Group {
                    switch model.step {
                    case .welcome: Step1Welcome(model: model, size: geo.size, onEntrance: { settle(.welcome, after: 0.8) })
                    case .capabilities: Step2Capabilities(model: model, size: geo.size)
                    case .evil: evilStep ?? AnyView(Step3Evil(model: model, size: geo.size))
                    case .preparing: Step4Preparing(model: model, status: status, size: geo.size)
                    }
                }
                // NFR-A3 / M9.T01 step 4 (keyboard paths, "onboarding steps"): the shown step is identifiable, so a
                // keyboard-only run can tell which step Return / ⌘[ reached. A containing group: the step's own ids
                // (`onb.*`) stay on its controls (Q-015 r6).
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step\(model.step.rawValue)")
                .transition(.opacity)
                OnboardingChrome(model: model, settled: settledStep == model.step)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(.named(OnboardingLayout.canvasSpace))
            .environment(\.onbCanvasSize, geo.size)
        }
        .animation(.smooth(duration: 0.32), value: model.step)
        // Step 1's entrance plays when the window first shows, after the view's first update: start its settle clock
        // again then, or the marker came up while the text was still fading in.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            guard model.step == .welcome else { return }
            settle(.welcome, after: 0.8)
        }
        .onChange(of: model.step, initial: true) { _, step in
            // Runs beside the crossfade; its completion is the step's end of motion: the 0.32 s crossfade, and on step 1
            // the entrance stagger too (`motion.onboarding.stagger`: 6 × 60 ms + 400 ms = 0.76 s).
            settle(step, after: step == .welcome ? 0.8 : 0.32)
        }
        .environment(\.colorScheme, .dark)
        .background(Color.black)
    }
}

/// The art, per step.
struct OnboardingBackground: View {
    let step: OnboardingModel.Step

    static let artURL = Bundle.module.url(forResource: "dreamworld", withExtension: "jpg", subdirectory: "Onboarding")
    static let art: NSImage? = artURL.flatMap(NSImage.init(contentsOf:))
    /// `onb.art.desaturate` (saturation 0.08, brightness −0.35), baked once with Core Image so every renderer (window,
    /// snapshot, Reduce Transparency) shows the same pixels.
    static let artDesaturated: NSImage? = {
        guard let url = artURL, let input = CIImage(contentsOf: url),
              let f = CIFilter(name: "CIColorControls") else { return art }
        f.setValue(input, forKey: kCIInputImageKey)
        f.setValue(0.08, forKey: kCIInputSaturationKey)
        f.setValue(-0.35, forKey: kCIInputBrightnessKey)
        f.setValue(1.0, forKey: kCIInputContrastKey)
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: input.extent) else { return art }
        return NSImage(cgImage: cg, size: input.extent.size)
    }()

    private var desaturated: Bool { step != .welcome }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let art = desaturated ? Self.artDesaturated : Self.art {
                    Image(nsImage: art)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                }
                if step == .evil {
                    // `evil.onboarding.gradient` over the desaturated art at 15% (S-03: a different "world").
                    LinearGradient(gradient: .evilOnboardingGradient, startPoint: .top, endPoint: .bottom).opacity(0.85)
                    RadialGradient(colors: [Color(red: 0.55, green: 0.08, blue: 0.08).opacity(0.25), .clear], center: .bottom,
                                   startRadius: 0, endRadius: geo.size.height * 0.9)
                } else if step == .welcome {
                    Color.onbScrimStep1
                    // `onb.scrim.left` (M9.T03): the hero-image treatment under the left text column, dark at the left
                    // edge and gone by 55 % of the width, so the art on the right stays clear.
                    OnboardingLeftScrim()
                } else {
                    // The reference's steps 2/4 sit near black: CIColorControls brightness alone leaves the clouds light,
                    // so a scrim keeps meta text ≥ 4.5:1 on the brightest region (H3).
                    Color.black.opacity(0.6)
                    LinearGradient(colors: [.black.opacity(0.2), .clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Wordmark, tag, Back, step counter and the pill handle.
struct OnboardingChrome: View {
    @Bindable var model: OnboardingModel
    var settled = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(CopyKey("onb.brand.name"))
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Color.onbTextHeadline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(CopyKey("onb.brand.tag"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.onbTextBody)
                    .onbGlassChip()  // M9.T03: a small glass chip over the bright sky
            }
            .padding(.top, 36)
            Spacer(minLength: 0)
            ZStack {
                HStack {
                    if model.step != .welcome {  // step 4 too (onboarding_page4): the downloads keep running
                        Button { model.back() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.left").font(.system(size: 12, weight: .semibold))
                                Text(CopyKey("onb.nav.back"))
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.onbTextBody)
                            .contentShape(Rectangle())
                        }
                            .accessibilityIdentifier("onb.nav.back")
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .background {  // ⌘[ = Back as well (NFR-A3)
                            Button("") { model.back() }.keyboardShortcut("[", modifiers: .command).hidden()
                        }
                    }
                    Spacer()
                    Text(CopyText(CopyKey("onb.nav.step"), ["n": String(model.step.rawValue)]))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.onbTextMeta)
                        #if DEBUG
                        .accessibilityIdentifier(settled ? "onb.nav.step.settled" : "onb.nav.step")
                        #endif
                        .onbGlassChip()  // M9.T03: a small glass chip over the bright rock
                }
                Capsule()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 34, height: 5)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 26)
        }
        .padding(.horizontal, OnboardingLayout.margin)
    }
}

enum OnboardingLayout {
    /// `layout.onboarding.margin`.
    static let margin: CGFloat = 60
    /// M10 visual QA (S-02): the reference's inset row of compact glass cards (about two thirds of the window, centred),
    /// not a full-width row of 316 × 160 tiles.
    static let cardSize = CGSize(width: 232, height: 124)
    static let cardGap: CGFloat = 18
    /// Cards wrap 2×2 when a row of four would be narrower than this per card (S-02).
    static let minCardWidth: CGFloat = 196
    /// The canvas the art fills; the glass cards sample the same art in its coordinates.
    static let canvasSpace = "onb.canvas"
}

extension EnvironmentValues {
    /// The onboarding canvas size (the art's frame), for glass that shows the art behind it.
    @Entry var onbCanvasSize: CGSize = .zero
}

/// `onb.glass.card` (M10 visual QA): frosted glass that shows the *colour* art behind the card (the steps' own art
/// is desaturated), blurred and darkened enough that white text on it keeps 4.5:1 on the brightest clouds.
struct OnboardingArtGlass: View {
    var colour = true
    var dim: Double = 0.55
    @Environment(\.onbCanvasSize) private var canvas

    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .named(OnboardingLayout.canvasSpace))
            if canvas != .zero, let art = colour ? OnboardingBackground.art : OnboardingBackground.artDesaturated {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .offset(x: -f.minX, y: -f.minY)
                    .blur(radius: 14, opaque: true)
            }
        }
        .overlay { Color.black.opacity(dim) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
