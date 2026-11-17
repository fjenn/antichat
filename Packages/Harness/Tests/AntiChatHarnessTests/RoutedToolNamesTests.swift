// Every tool name a route or a composer chip points at must be a registered tool. `file_output` and the "file" chip
// named `create_file`, and `memory_write` a tool of that name; neither exists (the file tools are one per type, the
// memory tool is `memory`), so a routed file or memory turn brought no tool.
import AntiChatEngineProtocol
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct RoutedToolNamesTests {
    /// The app's registry with every switch on and every pack installed (the media tools by their definitions' names:
    /// registering them needs a job queue).
    static func registeredNames() throws -> Set<String> {
        let db = try AppDatabase.inMemory()
        let registry = ToolRegistry.m1(scriptedTools: false)
        registry.register(SheetTools.queryData())
        [FileOutTools.createDocument(), FileOutTools.createSpreadsheet(), FileOutTools.createPresentation(),
         FileOutTools.createChart(), FileOutTools.exportTable()].forEach(registry.register)
        WebSearchTools.install(into: registry, tier: { "T1" }).forEach(NotificationCenter.default.removeObserver)
        registry.register(MemoryRuntime.for(db).tool())
        return Set(registry.all.map(\.name)).union([CreateImageTool.name, EditImageTool.name, CreateVideoTool.name])
    }

    @Test func everyRouteToolIsRegistered() throws {
        let names = try Self.registeredNames()
        for route in Route.allCases {
            for tool in route.tools { #expect(names.contains(tool), "route \(route.rawValue) names \(tool), which is not a tool") }
        }
        #expect(Route.intents.allSatisfy { !$0.tools.isEmpty })
        #expect(names.contains(ToolPruner.editTool))
        for tool in ToolPruner.alwaysOn { #expect(names.contains(tool)) }
        #expect(Set(Route.fileTools) == Set(FileToolsTools.createNames))
    }

    @Test(arguments: ["image", "video", "web", "readUrl", "file"])
    func everyChipToolIsRegistered(chip: String) throws {
        let tool = try #require(ChipOverride.toolName(forChip: chip))
        #expect(try Self.registeredNames().contains(tool), "chip \(chip) names \(tool), which is not a tool")
    }

    /// A file route lists five tools; the one the message is about goes first, so it survives a small tier's cut.
    @Test func fileFamilyIsRankedBySimilarity() {
        let eligible = (Route.fileTools + ["get_time", "web_search", "memory", "echo"]).map {
            ToolSchema(name: $0, description: "d", parametersJSON: #"{"type":"object","properties":{}}"#)
        }
        let hits = [ToolIndex.Hit(name: "create_presentation", fusedScore: 0.9, relevant: true)]
        let s = ToolSelector.select(eligible: eligible, routed: Route.fileOutput.tools, hits: hits, tier: .t0,
                                    budget: .init(maxPerStep: 3, schemaTokenCap: 5000))
        #expect(s.tools.map(\.name) == ["create_presentation", "create_document", FindToolsTool.name])
        #expect(ToolSelector.rankFamily(["web_search"] + Route.fileTools, hits: hits).prefix(2) == ["web_search", "create_presentation"])
    }
}
