// ModelManifest layout + hashing, and the shipped thresholds.json (M4.T01 step 4).
import CryptoKit
import Foundation
import Testing
@testable import ChildSafetyCheck

@Suite struct ManifestTests {
    @Test func standardLayoutUsesCatalogKeys() {
        let dir = URL(fileURLWithPath: "/m")
        let m = ModelManifest.standard(modelDirectory: dir, sha256: ["csc-nudity": "a", "csc-age": "b"])
        #expect(m.nudity.path == "/m/csc-nudity/onnx/model.onnx")
        #expect(m.age.path == "/m/csc-age/mivolo_v2_age.onnx")
        #expect(m.nudity2 == nil)
        #expect(m.ageBins.path == "/m/csc-age-bins/model.safetensors")
        #expect(m.files.map(\.key) == ["csc-nudity", "csc-age", "csc-age-bins"])
        let m2 = ModelManifest.standard(modelDirectory: dir, sha256: ["csc-nudity": "a", "csc-age": "b", "csc-nudity2": "c"])
        #expect(m2.nudity2?.path == "/m/csc-nudity2/marqo-nsfw-384.onnx")
        #expect(m2.files.map(\.key) == ["csc-nudity", "csc-age", "csc-age-bins", "csc-nudity2"])
    }

    @Test func sha256MatchesCryptoKitAcrossChunks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "csc-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        #expect(ModelManifest.sha256Hex(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })  // > one 8 MB chunk
        try big.write(to: url)
        #expect(ModelManifest.sha256Hex(of: url) == SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined())
        #expect(ModelManifest.sha256Hex(of: url.appending(path: "nope")) == nil)
    }

    @Test func uppercaseExpectedHashAccepted() throws {
        let (dir, sha) = try FailClosedTests.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        let upper = sha.mapValues { $0.uppercased() }
        #expect(throws: Never.self) { try ModelManifest.standard(modelDirectory: dir, sha256: upper).verify() }
    }

    @Test func bundledThresholdsAreVersionedSpecValues() throws {
        let t = try Thresholds.bundled()
        #expect(t.version >= 1)
        // The rule's inputs are all present and sane; values may change by calibration (version + 1).
        #expect((0...1).contains(t.tN) && t.mFace >= 0 && t.mBody >= 0 && t.timeout > 0)
        #expect(t.minFaceConfidence == 0.5 && t.minFaceSide == 24 && t.minFaceInBody == 0.6)
        // v3 (A-M4-T02b): the body-only age-bin signal is on in the shipped values.
        #expect(t.version >= 3 && t.tAgeBins.isFinite && (0...1).contains(t.tAgeBins))
    }

    @Test func decodeRejectsBadFilesAndMapsNullSecondSignalToOff() throws {
        let ok = #"{"version":3,"T_n":0.4,"T_n2":null,"m_face":8,"m_body":12,"face_min_conf":0.5,"face_min_side_px":24,"face_in_body_min":0.6,"timeout_ms":1500}"#
        let t = try Thresholds.decode(Data(ok.utf8))
        #expect(t.version == 3 && t.tN == 0.4 && t.tN2 == .infinity && t.mFace == 8 && t.timeout == 1.5)
        #expect(!DecisionRule.isNude(n: 0.1, n2: 0.99, t))  // second signal off
        #expect(t.tAgeBins == .infinity)  // absent T_age_bins (files before v3) = age-bin signal off
        let v3 = try Thresholds.decode(Data(ok.replacingOccurrences(of: #""m_body":12"#, with: #""m_body":12,"T_age_bins":0.4"#).utf8))
        #expect(v3.tAgeBins == 0.4)
        #expect(throws: (any Error).self) {
            _ = try Thresholds.decode(Data(ok.replacingOccurrences(of: #""m_body":12"#, with: #""m_body":12,"T_age_bins":1.5"#).utf8))
        }
        for bad in [ok.replacingOccurrences(of: #""T_n":0.4"#, with: #""T_n":1.4"#),
                    ok.replacingOccurrences(of: #""version":3"#, with: #""version":0"#),
                    ok.replacingOccurrences(of: #""timeout_ms":1500"#, with: #""timeout_ms":0"#),
                    ok.replacingOccurrences(of: #","m_body":12"#, with: ""),
                    "not json"] {
            #expect(throws: (any Error).self) { _ = try Thresholds.decode(Data(bad.utf8)) }
        }
    }
}
