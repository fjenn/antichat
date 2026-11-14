// M4.T03 step 3 (R-285 AC5, S-11 blocked state): what a withheld Photo/Video output becomes. Neutral grey, the copy
// key verbatim, no detail, no retry, no lecture (D-005/D-006). Same in Normal and Evil.
import AntiChatDesign
import SwiftUI

public struct BlockedMediaTile: View {
    public enum Kind: Sendable { case image, video }
    let kind: Kind
    /// The output's aspect ratio (width / height), so the tile keeps the placeholder's footprint.
    let aspect: CGFloat

    public init(kind: Kind, aspect: CGFloat = 1) {
        self.kind = kind
        self.aspect = aspect > 0 ? aspect : 1
    }

    static func key(_ kind: Kind) -> CopyKey { CopyKey(kind == .image ? "media.imageBlocked" : "media.videoBlocked") }

    public var body: some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.surfaceRaised)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
            }
            .overlay {
                Text(Self.key(kind)).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center).padding(Spacing.space3)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: 512)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("media.blocked")
    }
}

/// M4.T03 step 3 (R-285 AC6): shown at Photo/Video entry points when the detectors are missing or damaged. No job
/// runs; the button re-downloads the detector files (G-052 repair) of the size given.
public struct SafetyMissingCard: View {
    let sizeBytes: Int64
    let onRepair: () -> Void

    public init(sizeBytes: Int64, onRepair: @escaping () -> Void) {
        self.sizeBytes = sizeBytes
        self.onRepair = onRepair
    }

    static func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private var repairLabel: Text {
        sizeBytes > 0 ? Text(CopyText(CopyKey("safety.missing"), ["size": Self.sizeText(sizeBytes)])) : Text(CopyKey("storage.repair"))
    }

    /// vq/voice-mac-capture (S-11): the card looked like the generic "couldn't be made" failure (plain grey text, a
    /// grey button). It now leads with a shield glyph in the warning colour and its one action as the default button,
    /// so the cause (ChildSafetyCheck) and the fix (repair) read at a glance. A size of 0 (not known yet) names no size.
    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(CopyKey("safety.missing.body")).typeStyle(.callout).fontWeight(.medium).foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRepair) { repairLabel }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .probeID("safety.missing.repair")
            }
        }
        .padding(Spacing.space3)
        .frame(maxWidth: 420, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("safety.missing")  // + the DEBUG probe anchor (M10.T09 AT-FA-08)
    }
}
