// M10.T01 step 2 (R-305; ci-release §4): what signed this running app. About shows "Development build — not
// notarized" (`about.unnotarized`) unless the app's own signature has a Developer ID Application leaf
// certificate (adhoc / Apple Development builds are UNNOTARIZED by definition, M10.md "Signing modes").
// Read once, off the code signature itself (SecCodeCopySigningInformation); never spawns codesign.
import Foundation
import Security

public enum BuildSignature: Equatable, Sendable {
    case adhoc
    case development(team: String?)
    case developerID(team: String?)
    case unsigned

    /// The running app's signature (computed once).
    public static let current: BuildSignature = read(bundleURL: Bundle.main.bundleURL)

    /// Only Developer ID builds go through notarization (devid mode); everything else is a development build.
    public var isDeveloperID: Bool { if case .developerID = self { true } else { false } }

    public static func read(bundleURL: URL) -> BuildSignature {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .unsigned }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else {
            // Signed without certificates = ad-hoc (kSecCodeSignatureAdhoc); no signature info at all = unsigned.
            return dict[kSecCodeInfoIdentifier as String] == nil ? .unsigned : .adhoc
        }
        return classify(leafSummary: SecCertificateCopySubjectSummary(leaf) as String? ?? "", team: team)
    }

    /// The leaf certificate's common name decides (pure; unit-tested).
    public static func classify(leafSummary: String, team: String?) -> BuildSignature {
        leafSummary.hasPrefix("Developer ID Application:") ? .developerID(team: team) : .development(team: team)
    }
}
