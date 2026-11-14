import Foundation
import Testing

// ANTICHAT-PATCH: UP-OS-034 ported test imports the OsaurusVendored target
@testable import OsaurusVendored
// ANTICHAT-PATCH-END

/// Unit coverage for the Seatbelt (`sandbox-exec`) fallback backend used
/// on macOS versions before 26. Pins the pieces that must not drift:
/// backend selection never picks Seatbelt on Tahoe+, the generated
/// profile is deny-by-default with the right write grants, "proxy"
/// network mode fails closed, and the `/workspace` → host path rewrite
/// only touches whole path components.
@Suite
struct SeatbeltSandboxTests {

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    /// `isSupported` is read on the main actor from hot paths (chat preview
    /// recomposition via `effectiveAutonomousExec`), so it must be a
    /// process-lifetime constant rather than a filesystem probe per access.
    @Test("isSupported is resolved once and matches the host binary")
    func isSupportedIsStableAndAccurate() {
        let expected = FileManager.default.isExecutableFile(atPath: SeatbeltSandbox.sandboxExecPath)
        #expect(SeatbeltSandbox.isSupported == expected)
        #expect(SeatbeltSandbox.isSupported == SeatbeltSandbox.isSupported)
    }

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // MARK: - Backend-branched prompt / flag surface

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // MARK: - Profile generation

    @Test("profile is deny-by-default and grants workspace + temp writes")
    func profileShape() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/Users/me/.osaurus/container/workspace",
            tempDir: "/tmp/osaurus-seatbelt",
            network: .allowed,
            developerDirectory: "/Applications/Xcode.app/Contents/Developer"
        )
        #expect(profile.hasPrefix("(version 1)\n(deny default)"))
        #expect(profile.contains("(subpath \"/Users/me/.osaurus/container/workspace\")"))
        #expect(profile.contains("(subpath \"/private/tmp/osaurus-seatbelt\")"))
        #expect(profile.contains("(subpath \"/Applications/Xcode.app/Contents\")"))
        for cacheFile in SeatbeltSandbox.xcrunCacheFiles {
            #expect(profile.contains("(literal \"\(cacheFile)\")"))
        }
        #expect(profile.contains("(allow network*)"))
        // No blanket home-directory read grant.
        #expect(!profile.contains("(subpath \"/Users\")"))
        // Filesystem confinement is not enough if arbitrary code can connect
        // to every user-session XPC service.
        #expect(!profile.contains("(allow mach-lookup"))

        // The developer tree is read-only. It must appear only in the
        // read grant, never in the workspace/scratch write section.
        let writeSection = profile.components(separatedBy: "(allow file-read* file-write*").last ?? ""
        #expect(!writeSection.contains("/Applications/Xcode.app/Contents"))
        for cacheFile in SeatbeltSandbox.xcrunCacheFiles {
            #expect(!writeSection.contains(cacheFile))
        }
    }

    @Test("profile omits an unavailable developer directory")
    func profileWithoutDeveloperDirectory() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/w",
            tempDir: "/t",
            network: .denied,
            developerDirectory: nil
        )
        #expect(!profile.contains("/Applications"))
    }

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    // ANTICHAT-PATCH: UP-OS-035 ported test: drop tests that need the Osaurus sandbox executor/manager/prompt templates (not vendored; M6 G-032 ports the executor)
    // ANTICHAT-PATCH-END

    @Test("network none denies network in the profile")
    func profileDeniesNetwork() {
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: "/w", tempDir: "/t", network: .denied)
        #expect(profile.contains("(deny network*)"))
        #expect(!profile.contains("(allow network*)"))
    }

    @Test("proxy allowlist mode fails closed to no network")
    func proxyModeFailsClosed() {
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "outbound") == .allowed)
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "none") == .denied)
        // Seatbelt can't enforce a domain allowlist — it must not silently
        // widen "proxy" to unrestricted egress.
        #expect(SeatbeltSandbox.NetworkPolicy.from(configNetwork: "proxy") == .denied)
    }

    @Test("profile paths with quotes are escaped")
    func profileEscaping() {
        #expect(SeatbeltSandbox.escapeProfilePath(#"/a/"b"/c"#) == #"/a/\"b\"/c"#)
        #expect(SeatbeltSandbox.escapeProfilePath(#"/a\b"#) == #"/a\\b"#)
    }

    // MARK: - Path mapping

    private let root = "/Users/me/.osaurus/container/workspace"

    @Test("guest workspace paths map to the host workspace")
    func mapsWorkspacePaths() {
        #expect(
            SeatbeltPathMapper.mapToHost("cat /workspace/agents/a/notes.txt", workspaceRoot: root)
                == "cat \(root)/agents/a/notes.txt")
        #expect(SeatbeltPathMapper.mapToHost("ls /workspace", workspaceRoot: root) == "ls \(root)")
        #expect(
            SeatbeltPathMapper.mapToHost("cd /workspace && ls /workspace/shared", workspaceRoot: root)
                == "cd \(root) && ls \(root)/shared")
    }

    @Test("non-workspace tokens are left untouched")
    func leavesOtherPathsAlone() {
        #expect(
            SeatbeltPathMapper.mapToHost("ls /workspaces/other", workspaceRoot: root)
                == "ls /workspaces/other")
        #expect(
            SeatbeltPathMapper.mapToHost("ls foo/workspace/bar", workspaceRoot: root)
                == "ls foo/workspace/bar")
        #expect(
            SeatbeltPathMapper.mapToHost("echo no paths here", workspaceRoot: root)
                == "echo no paths here")
    }

    @Test("trailing slash on the host root does not double up")
    func trailingSlashRoot() {
        #expect(
            SeatbeltPathMapper.mapToHost("/workspace/x", workspaceRoot: root + "/")
                == "\(root)/x")
    }

    @Test("env values are mapped")
    func mapsEnvValues() {
        let mapped = SeatbeltPathMapper.mapEnvToHost(
            ["HOME": "/workspace/agents/a", "LANG": "C"], workspaceRoot: root)
        #expect(mapped["HOME"] == "\(root)/agents/a")
        #expect(mapped["LANG"] == "C")
    }
}
