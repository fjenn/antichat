// M7.T06 step 8 (R-081 AC4): `catalog/mcp-curated.yaml` compiles into the `mcp_curated` section (≥ 10 https servers,
// unique ids, supported auth kinds) and decodes as AntiChatTools' MCPCuratedEntry shape; the ids match the app's
// built-in list (AntiChatTools/MCP/MCPCurated.defaultIDs, checked by MCPCuratedTests on the app side).
@testable import catalog_tool
import Foundation
import Testing

struct MCPCuratedSectionTests {
    @Test func yamlCompilesToTheSection() throws {
        let section = try #require(try Build.mcpCurated(SearchEnginesSectionTests.repo.appending(path: "catalog/mcp-curated.yaml")))
        #expect(section.count >= 10)
        var ids: [String] = []
        for case .object(let o) in section {
            guard case .string(let id) = o["id"], case .string(let url) = o["url"], case .string(let auth) = o["auth"] else {
                Issue.record("id/url/auth"); continue
            }
            ids.append(id)
            #expect(url.hasPrefix("https://") && ["none", "token", "oauth"].contains(auth))
        }
        #expect(ids == ["github", "linear", "sentry", "huggingface", "deepwiki", "cloudflare", "vercel", "supabase", "neon",
                        "netlify", "notion", "atlassian", "exa_search", "stripe"])
    }

    @Test func badListsAreRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appending(path: "mcp-curated.yaml")
        try "servers:\n  - {id: a, name: A, url: \"http://a\", auth: none}\n".write(to: f, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try Build.mcpCurated(f) }
        #expect(try Build.mcpCurated(nil) == nil)
    }
}
