// M10.T01 step 2: the About "Development build — not notarized" label keys off BuildSignature. Classification by
// the leaf certificate's common name; real signatures read from system and ad-hoc-signed code on this Mac.
//   make test-unit FILTER=BuildSignatureTests
import Foundation
import Testing
@testable import AntiChatPlatform

struct BuildSignatureTests {
    @Test func developerIDLeafIsDeveloperID() {
        let s = BuildSignature.classify(leafSummary: "Developer ID Application: Finn Jennen (446XT9839S)", team: "446XT9839S")
        #expect(s == .developerID(team: "446XT9839S"))
        #expect(s.isDeveloperID)
    }

    @Test(arguments: ["Apple Development: someone (ABCDE12345)", "Apple Distribution: x", "Software Signing", ""])
    func everyOtherLeafIsDevelopment(_ summary: String) {
        #expect(!BuildSignature.classify(leafSummary: summary, team: nil).isDeveloperID)
    }

    @Test func appleSignedSystemAppIsNotDeveloperID() {
        // Platform binaries are signed by "Software Signing" (Apple), never Developer ID.
        let s = BuildSignature.read(bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(!s.isDeveloperID)
        #expect(s != .unsigned && s != .adhoc)
    }

    @Test func adhocSignedCodeIsAdhoc() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buildsig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("true")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: bin)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", bin.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        #expect(BuildSignature.read(bundleURL: bin) == .adhoc)
    }

    @Test func missingPathIsUnsigned() {
        #expect(BuildSignature.read(bundleURL: URL(fileURLWithPath: "/nonexistent/AntiChat.app")) == .unsigned)
    }
}
