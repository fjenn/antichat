// M2.T06 AT-NFR-D3 / AT-NFR-D4: the default download per tier (all Normal packs except Video, D-010) and the
// Chat-only download stay within their NFR caps (read from nfr.md). Sizes = Σ unique sha256 from the catalog
// (= catalog.lock.json); shared blobs count once; files already present are subtracted (E.2.3 step 6).
// Writes build/at/AT-NFR-D3/sizes.csv and build/at/AT-NFR-D4/sizes.csv. Measured confirmation: M2.T25 (`du -sk`).
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct DownloadSizeTests {
    let catalog: ModelCatalog = try! SelectorFixtures.baseline()

    func gb(_ b: Int64) -> Double { Double(b) / 1e9 }

    @Test func defaultAndChatOnlyWithinCaps() throws {
        let d3 = try SelectorFixtures.caps("NFR-D3"), d4 = try SelectorFixtures.caps("NFR-D4")
        #expect(d3.count == 5 && d4.count == 5)
        let selector = ModelSelector(catalog: catalog)
        var rows3 = ["fixture,cell,tier,default_gb,cap_gb,pass,video_gb_separate"], rows4 = ["fixture,cell,tier,chat_only_gb,cap_gb,pass"]
        let onDemand = Set(catalog.onDemand)
        for name in SelectorFixtures.names {
            let p = try SelectorFixtures.profile(name)
            let s = selector.select(profile: p)
            let all = gb(DownloadSize.bytes(ids: s.installIDs(packs: [.chat, .voice, .photo], modes: [.normal], onDemand: onDemand), catalog: catalog))
            let chat = gb(DownloadSize.bytes(ids: s.installIDs(packs: [.chat], modes: [.normal], onDemand: onDemand), catalog: catalog))
            let video = gb(DownloadSize.bytes(ids: s.installIDs(packs: [.video], modes: [.normal]), catalog: catalog))
            let c3 = try #require(d3[p.tier]), c4 = try #require(d4[p.tier])
            #expect(all <= c3, "\(name): \(all) GB > NFR-D3 \(c3)")
            #expect(chat <= c4, "\(name): \(chat) GB > NFR-D4 \(c4)")
            #expect(chat > 0 && all >= chat)
            rows3.append("\(name),\(s.cellKey),\(p.tier.rawValue),\(String(format: "%.2f", all)),\(c3),\(all <= c3 ? 1 : 0),\(String(format: "%.2f", video))")
            rows4.append("\(name),\(s.cellKey),\(p.tier.rawValue),\(String(format: "%.2f", chat)),\(c4),\(chat <= c4 ? 1 : 0)")
        }
        try SelectorFixtures.write(rows3.joined(separator: "\n") + "\n", to: "build/at/AT-NFR-D3/sizes.csv")
        try SelectorFixtures.write(rows4.joined(separator: "\n") + "\n", to: "build/at/AT-NFR-D4/sizes.csv")
    }

    @Test func sharedBlobsCountOnceAndPresentFilesAreSubtracted() throws {
        let klein = try #require(catalog.models["img-klein-q8"]), zit = try #require(catalog.models["img-zit-q8"])
        let te = try #require(catalog.models["img-te-q8"])
        let both = DownloadSize.bytes(ids: ["img-klein-q8", "img-te-q8", "img-zit-q8", "img-te-q8"], catalog: catalog)
        #expect(both == klein.totalBytes + zit.totalBytes + te.totalBytes - sharedREADME(klein, zit))
        let present = Set(te.files.map(\.sha256))
        #expect(DownloadSize.bytes(ids: ["img-klein-q8", "img-te-q8"], catalog: catalog, present: present)
            == DownloadSize.bytes(ids: ["img-klein-q8"], catalog: catalog))
        #expect(DownloadSize.bytes(ids: ["chat-0.8b"], catalog: catalog) > 0)  // never "0.0 GB" for a missing model
    }

    /// Files with the same sha256 in two entries (e.g. an identical README) are downloaded once.
    func sharedREADME(_ a: CatalogModel, _ b: CatalogModel) -> Int64 {
        let bs = Dictionary(b.files.map { ($0.sha256, $0.size) }, uniquingKeysWith: { x, _ in x })
        return a.files.filter { bs[$0.sha256] != nil }.reduce(0) { $0 + $1.size }
    }
}
