// csc-bench: latency and calibration harness for ChildSafetyCheck (docs/prd/M0.md M0.T08; M4 G-048).
//
//   csc-bench latency  --images DIR [--runs 20] [--limit 20] [--ep coreml|cpu]
//   csc-bench nudity   --set DIR --labels labels.csv        (columns: file,label  label ∈ nsfw_adult|sfw)
//   csc-bench age      --set DIR --labels ages.csv          (columns: file,age[,face_x0,face_y0,face_x1,face_y1,
//                                                            person_x0,person_y0,person_x1,person_y1]; -1 = none)
//   csc-bench overblock --set DIR --labels labels.csv       (full rule on every image, block rate per label)
//   csc-bench preview-size --set DIR --labels ages.csv [--sides 0,512,384,256,128] [--every N]
//                                                            (M4 review P1-3: the age branch on non-sexual scenes
//                                                            rescaled so the LONGER side = each value, 0 = as stored;
//                                                            minor-flag rate per age band, faces/people found; aggregates)
//   csc-bench bins-check --images DIR [--limit 8]           (age-bin probabilities on content-free CC0 photos, to
//                                                            compare the Accelerate forward with the reference)
//   csc-bench stream                                         (M5 preview investigation: length-prefixed records on
//                                                            stdin, [u32 BE meta len][meta JSON][u32 BE image len][JPEG/PNG];
//                                                            one JSONL trace per record on stdout: the meta echoed + scores,
//                                                            verdict, failure, ms. Images stay in memory, never written)
//   common: [--models DIR] [--ep coreml|cpu] [--out result.json] [--tn X] [--mface Y] [--mbody Z] [--tbins W|off]
//           [--jobs N]
//
// Data rules (R-285 AC7, D-006, D-017): the nudity detector is only ever run on adult NSFW / SFW proxy sets and
// the age estimator only on non-sexual faces. This tool prints and writes AGGREGATES ONLY: no image, file name or
// path from a calibration set appears in its output.
import ChildSafetyCheck
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

// MARK: - CLI

struct Args {
    var command = ""
    var opts: [String: String] = [:]
    init() {
        var it = CommandLine.arguments.dropFirst().makeIterator()
        command = it.next() ?? ""
        while let a = it.next() {
            guard a.hasPrefix("--") else { continue }
            opts[String(a.dropFirst(2))] = it.next() ?? ""
        }
    }
    func str(_ k: String, _ d: String? = nil) -> String? { opts[k] ?? d }
    func int(_ k: String, _ d: Int) -> Int { opts[k].flatMap(Int.init) ?? d }
    func dbl(_ k: String) -> Double? { opts[k].flatMap(Double.init) }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("csc-bench: \(msg)\n".utf8))
    exit(2)
}

func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

// Read-only after start-up; nonisolated so detector work off the main actor can read them.
nonisolated let args = Args()
nonisolated let modelsDir = expand(args.str("models", ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"]
    .map { "\($0)/Models" } ?? "~/Library/Application Support/AntiChat-Dev/Models")!)
nonisolated let provider = ExecutionProvider(rawValue: args.str("ep", "coreml")!) ?? .coreml
nonisolated let thresholds: Thresholds = {
    // Shipped values (Resources/thresholds.json) unless overridden; `--tn2 off` disables the second signal.
    var t = (try? Thresholds.bundled()) ?? Thresholds()
    if args.str("tn2") == "off" { t.tN2 = .infinity }
    if let v = args.dbl("tn") { t.tN = v }
    if let v = args.dbl("tn2") { t.tN2 = v }
    if let v = args.dbl("mface") { t.mFace = v }
    if let v = args.dbl("mbody") { t.mBody = v }
    if args.str("tbins") == "off" { t.tAgeBins = .infinity }
    if let v = args.dbl("tbins") { t.tAgeBins = v }
    return t
}()
/// Compiled Core ML cache ("none" disables, to measure cold loads).
nonisolated let cacheDir: URL? = args.str("coreml-cache", "~/Library/Caches/AntiChat-Dev/csc-coreml") == "none"
    ? nil : expand(args.str("coreml-cache", "~/Library/Caches/AntiChat-Dev/csc-coreml")!)
nonisolated let jobs = max(1, args.int("jobs", 4))

// MARK: - Helpers

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func percentile(_ xs: [Double], _ p: Double) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    let rank = p / 100 * Double(s.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
}

func r4(_ x: Double?) -> Any { x.map { ($0 * 10000).rounded() / 10000 } ?? NSNull() }

func peakFootprintMB() -> Double {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
}

func currentFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func readCSV(_ url: URL) -> [[String: String]] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { die("cannot read labels") }
    var lines = text.split(whereSeparator: \.isNewline).map(String.init)
    guard !lines.isEmpty else { return [] }
    let header = lines.removeFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.map { line in
        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return Dictionary(uniqueKeysWithValues: zip(header, cols))
    }
}

func writeOut(_ obj: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    if let out = args.str("out") {
        try! data.write(to: expand(out))
    }
    print(String(decoding: data, as: UTF8.self))
}

/// Parallel map with bounded concurrency, preserving order.
func pmap<T: Sendable, R: Sendable>(_ items: [T], _ f: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { g in
        var out = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(jobs, items.count) {
            let i = next; next += 1
            g.addTask { (i, await f(items[i])) }
        }
        var done = 0
        while let (i, r) = await g.next() {
            out[i] = r
            done += 1
            if done % 250 == 0 { FileHandle.standardError.write(Data("  \(done)/\(items.count)\n".utf8)) }
            if next < items.count {
                let j = next; next += 1
                g.addTask { (j, await f(items[j])) }
            }
        }
        return out.map { $0! }
    }
}

func makeCheck() -> (ChildSafetyCheck, Double) {
    let t0 = Date()
    do {
        let base = try ChildSafetyCheck(modelDirectory: modelsDir, provider: provider, cacheDirectory: cacheDir)
        let check = ChildSafetyCheck(detectors: base.detectors, thresholds: thresholds)
        return (check, Date().timeIntervalSince(t0))
    } catch {
        die("model load failed (fail closed): \(error)")
    }
}

func hostInfo() -> [String: Any] {
    func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    return ["cpu": sysctl("machdep.cpu.brand_string"),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "memory_gb": ProcessInfo.processInfo.physicalMemory / 1_073_741_824]
}

func thresholdsJSON(_ t: Thresholds) -> [String: Any] {
    ["version": t.version, "T_n": t.tN, "T_n2": t.tN2.isFinite ? t.tN2 : NSNull(), "m_face": t.mFace, "m_body": t.mBody, "T_age_bins": t.tAgeBins.isFinite ? t.tAgeBins : NSNull(),
     "face_conf_min": t.minFaceConfidence, "face_side_min_px": t.minFaceSide, "timeout_s": t.timeout]
}

// MARK: - latency (NFR-F7)

func latency() async {
    guard let dir = args.str("images") else { die("--images DIR required") }
    let runs = args.int("runs", 20), limit = args.int("limit", 20)
    let files = ((try? FileManager.default.contentsOfDirectory(at: expand(dir), includingPropertiesForKeys: nil)) ?? [])
        .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(limit)
    let images = files.compactMap(loadImage)
    guard images.count == limit else { die("expected \(limit) images, got \(images.count)") }
    let baseFootprint = currentFootprintMB()
    let (check, loadS) = makeCheck()
    var full: [Double] = [], asUsed: [Double] = [], perImageP95: [Double] = []
    var faces = 0, blocked = 0
    // F7 tail diagnosis (A-M9-T05-F7): per image (CC0 set order, no identity) the age queries and the stage medians, so a
    // slow tail is read from the record instead of inferred from face counts.
    var perImage: [[String: Any]] = []
    for img in images {
        _ = await check.evaluateDetailed(image: img, forceFullPath: true)  // warm-up, excluded
        var times: [Double] = []
        var stages: [String: [Double]] = [:]
        var faceQ = 0, bodyQ = 0
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let tr = await check.evaluateDetailed(image: img, forceFullPath: true)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            if tr.failure != nil { die("detector failure during latency run: \(tr.failure!)") }
            if tr.verdict == .block { blocked += 1 }
            faces = max(faces, tr.faceAges.count + tr.bodyOnlyAges.count)
            faceQ = tr.faceAges.count
            bodyQ = tr.bodyOnlyAges.count
            let s = tr.stageMs
            for (k, v) in [("nudity", s.nudity), ("people", s.people), ("age_stage", s.ageStage), ("mivolo", s.mivolo),
                           ("bins", s.bins)] {
                if let v { stages[k, default: []].append(v) }
            }
        }
        full += times
        perImageP95.append(percentile(times, 95)!)
        perImage.append(["face_queries": faceQ, "body_only_queries": bodyQ, "p50_ms": r4(percentile(times, 50)),
                         "max_ms": r4(times.max()),
                         "stage_p50_ms": stages.mapValues { r4(percentile($0, 50)) }])
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = await check.evaluate(image: img)
        asUsed.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    writeOut([
        "command": "latency", "ep": provider.rawValue, "images": images.count, "runs_per_image": runs,
        "n": full.count, "image_px": "\(images[0].width)x\(images[0].height)",
        "full_path_ms": ["p50": r4(percentile(full, 50)), "p95": r4(percentile(full, 95)),
                         "max": r4(full.max()), "worst_image_p95": r4(perImageP95.max())],
        "as_used_sfw_ms": ["p50": r4(percentile(asUsed, 50)), "p95": r4(percentile(asUsed, 95)), "n": asUsed.count],
        // Raw timings of the content-free CC0 latency set (perf report samples; no image identity).
        "full_path_samples_ms": full.map { (($0 * 1e4).rounded() / 1e4) },
        "max_age_queries_per_image": faces, "blocked_runs": blocked, "per_image": perImage,
        "model_load_s": r4(loadS), "peak_footprint_mb": r4(peakFootprintMB()),
        "footprint_after_mb": r4(currentFootprintMB()), "footprint_before_load_mb": r4(baseFootprint),
        "nfr": "NFR-F7", "target_p95_ms": 300, "pass": (percentile(full, 95) ?? 1e9) <= 300,
        "host": hostInfo(), "thresholds": thresholdsJSON(thresholds),
    ])
}

// MARK: - nudity (NFR-F1, part of F6)

struct NudityRow: Sendable { let n: Double?; let n2: Double?; let nsfw: Bool }

func nudity() async {
    guard let set = args.str("set"), let labels = args.str("labels") else { die("--set DIR --labels CSV required") }
    let base = expand(set)
    let rows = readCSV(base.appending(path: labels)).compactMap { r -> (URL, Bool)? in
        guard let f = r["file"], let l = r["label"], l == "nsfw_adult" || l == "sfw" else { return nil }
        return (base.appending(path: f), l == "nsfw_adult")
    }
    let (check, _) = makeCheck()
    let d = check.detectors
    let scored: [NudityRow] = await pmap(rows) { url, nsfw in
        guard let img = loadImage(url) else { return NudityRow(n: nil, n2: nil, nsfw: nsfw) }
        return NudityRow(n: try? d.nudity.nudityScore(img), n2: d.nudity2.flatMap { try? $0.nudityScore(img) }, nsfw: nsfw)
    }
    let ok = scored.filter { $0.n != nil }
    let pos = ok.filter(\.nsfw), neg = ok.filter { !$0.nsfw }
    var sweep: [[String: Any]] = []
    var chosen: Double? = nil
    for k in 1...19 {
        let t = Double(k) * 0.05
        for useMarqo in [false, true] where !useMarqo || d.nudity2 != nil {
            func flag(_ r: NudityRow) -> Bool { r.n! >= t || (useMarqo && (r.n2 ?? 0) >= thresholds.tN2) }
            let tp = pos.filter(flag).count, fp = neg.filter(flag).count
            let recall: Double? = pos.isEmpty ? nil : Double(tp) / Double(pos.count)
            let precision: Double? = (pos.isEmpty || tp + fp == 0) ? nil : Double(tp) / Double(tp + fp)
            let sfwRate: Double? = neg.isEmpty ? nil : Double(fp) / Double(neg.count)
            sweep.append(["T_n": r4(t), "with_marqo": useMarqo, "recall": r4(recall), "precision": r4(precision),
                          "sfw_flag_rate": r4(sfwRate)])
            if !useMarqo, let recall, let precision, recall >= 0.97, precision >= 0.90 { chosen = t }
        }
    }
    writeOut([
        "command": "nudity", "ep": provider.rawValue, "n_nsfw_adult": pos.count, "n_sfw": neg.count,
        "n_unreadable": scored.count - ok.count, "sweep": sweep,
        "sfw_score_p50": r4(percentile(neg.map { $0.n! }, 50)), "sfw_score_p99": r4(percentile(neg.map { $0.n! }, 99)),
        "chosen_T_n": r4(chosen), "nfr": "NFR-F1",
        "f1_status": pos.isEmpty ? "[PENDING-PRIVATE] no nsfw_adult rows" : (chosen != nil ? "pass" : "fail"),
    ])
}

// MARK: - age (NFR-F2)

struct AgeRow: Sendable { let truth: Double; let face: Double?; let bodyOnly: Double?; let young: Double? }

func box(_ r: [String: String], _ p: String) -> CGRect? {
    guard let x0 = r["\(p)_x0"].flatMap(Double.init), let y0 = r["\(p)_y0"].flatMap(Double.init),
          let x1 = r["\(p)_x1"].flatMap(Double.init), let y1 = r["\(p)_y1"].flatMap(Double.init),
          x0 >= 0, y0 >= 0, x1 > x0, y1 > y0 else { return nil }
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

func age() async {
    guard let set = args.str("set"), let labels = args.str("labels") else { die("--set DIR --labels CSV required") }
    let base = expand(set)
    let rows = readCSV(base.appending(path: labels)).compactMap { r -> (URL, Double, CGRect?, CGRect?)? in
        guard let f = r["file"], let a = r["age"].flatMap(Double.init), a >= 0 else { return nil }
        return (base.appending(path: f), a, box(r, "face"), box(r, "person"))
    }
    let (check, _) = makeCheck()
    let est = check.detectors.age
    let bins = check.detectors.ageBins
    let scored: [AgeRow] = await pmap(rows) { url, truth, faceBox, personBox in
        guard let img = loadImage(url) else { return AgeRow(truth: truth, face: nil, bodyOnly: nil, young: nil) }
        // Ground-truth boxes isolate the regressor (what is calibrated). No face box ⇒ the image is an
        // aligned face crop (UTKFace-style): whole image = face, black body.
        let face = faceBox.flatMap { ImageTensor.crop(img, $0) } ?? (faceBox == nil ? img : nil)
        let body = personBox.flatMap { ImageTensor.crop(img, $0) }
        let fa = face.flatMap { try? est.age(face: $0, body: body) }
        let ba = body.flatMap { try? est.age(face: nil, body: $0) }
        let young = body.flatMap { b in bins.flatMap { try? $0.youngProbability(b) } }
        return AgeRow(truth: truth, face: fa, bodyOnly: ba, young: young)
    }
    let ageDigest = digest(scored.map { r in [r.face, r.bodyOnly, r.young].map { $0.map { String($0.bitPattern, radix: 16) } ?? "-" }.joined(separator: ",") })
    func stats(_ get: (AgeRow) -> Double?, margins: ClosedRange<Int>) -> [String: Any] {
        let ok = scored.compactMap { r in get(r).map { (r.truth, $0) } }
        guard !ok.isEmpty else { return ["n": 0] }
        let mae = ok.map { abs($0.0 - $0.1) }.reduce(0, +) / Double(ok.count)
        let le15 = ok.filter { $0.0 <= 15 }, t1617 = ok.filter { $0.0 >= 16 && $0.0 < 18 }, ge30 = ok.filter { $0.0 >= 30 }
        let a1824 = ok.filter { $0.0 >= 18 && $0.0 < 30 }
        func rate(_ xs: [(Double, Double)], _ m: Double) -> Double? {
            xs.isEmpty ? nil : Double(xs.filter { $0.1 < thresholds.adultAge + m }.count) / Double(xs.count)
        }
        var sweep: [[String: Any]] = []
        for m in margins {
            let md = Double(m)
            sweep.append(["m": m, "recall_le15": r4(rate(le15, md)), "recall_16_17": r4(rate(t1617, md)),
                          "flag_rate_18_29": r4(rate(a1824, md)), "false_flag_ge30": r4(rate(ge30, md))])
        }
        func meets(_ m: Double) -> Bool {
            (rate(le15, m) ?? 0) >= 0.99 && (rate(t1617, m) ?? 0) >= 0.95 && (rate(ge30, m) ?? 1) <= 0.05
        }
        let feasible = margins.map(Double.init).filter(meets)
        let minors = ok.filter { $0.0 < 18 }
        return ["n": ok.count, "n_le15": le15.count, "n_16_17": t1617.count, "n_18_29": a1824.count, "n_ge30": ge30.count,
                "mae": r4(mae), "mae_minors": r4(minors.isEmpty ? nil : minors.map { abs($0.0 - $0.1) }.reduce(0, +) / Double(minors.count)),
                "max_estimate_minors": r4(minors.map(\.1).max()), "sweep": sweep,
                "feasible_margins": feasible, "min_feasible_margin": r4(feasible.min())]
    }
    let faceStats = stats(\.face, margins: 0...14)
    let bodyStats = stats(\.bodyOnly, margins: 0...20)
    // Body-only fused with the age bins (minor = MiVOLO body-only < 18 + m_body OR P(child + teen) ≥ T_age_bins):
    // the joint m_body × T_age_bins grid, rows with both signals only. Aggregates only.
    let both = scored.compactMap { r -> (Double, Double, Double)? in
        guard let b = r.bodyOnly, let y = r.young else { return nil }
        return (r.truth, b, y)
    }
    var fused: [String: Any] = ["n": both.count]
    if !both.isEmpty {
        func band(_ lo: Double, _ hi: Double) -> [(Double, Double, Double)] { both.filter { $0.0 >= lo && $0.0 < hi } }
        let le15 = band(0, 16), t1617 = band(16, 18), a1829 = band(18, 30), ge30 = band(30, 1000)
        var grid: [[String: Any]] = []
        var feasible: [[String: Any]] = []
        let tbinsGrid: [Double?] = [nil] + stride(from: 0.05, through: 0.951, by: 0.05).map { ($0 * 100).rounded() / 100 }
        for m in 0...20 {
            for tb in tbinsGrid {
                func flagged(_ x: (Double, Double, Double)) -> Bool {
                    x.1 < thresholds.adultAge + Double(m) || (tb.map { x.2 >= $0 } ?? false)
                }
                func rate(_ xs: [(Double, Double, Double)]) -> Double? {
                    xs.isEmpty ? nil : Double(xs.filter(flagged).count) / Double(xs.count)
                }
                let cell: [String: Any] = ["m_body": m, "T_age_bins": tb.map { r4($0) } ?? NSNull(),
                                           "recall_le15": r4(rate(le15)), "recall_16_17": r4(rate(t1617)),
                                           "flag_rate_18_29": r4(rate(a1829)), "false_flag_ge30": r4(rate(ge30))]
                grid.append(cell)
                if (rate(le15) ?? 0) >= 0.99, (rate(t1617) ?? 0) >= 0.95, (rate(ge30) ?? 1) <= 0.05 { feasible.append(cell) }
            }
        }
        let young = both.map(\.2)
        fused = ["n": both.count, "n_le15": le15.count, "n_16_17": t1617.count, "n_18_29": a1829.count, "n_ge30": ge30.count,
                 "young_p50_le15": r4(percentile(le15.map(\.2), 50)), "young_p50_ge30": r4(percentile(ge30.map(\.2), 50)),
                 "young_mean": r4(young.reduce(0, +) / Double(young.count)),
                 "grid": grid, "feasible": feasible]
    }
    let mf = thresholds.mFace
    func at(_ s: [String: Any], _ m: Double) -> Any {
        (s["sweep"] as? [[String: Any]])?.first { ($0["m"] as? Int) == Int(m) } ?? NSNull()
    }
    writeOut([
        "command": "age", "ep": provider.rawValue, "n_rows": rows.count, "scores_digest": ageDigest,
        "face": faceStats, "body_only": bodyStats, "body_only_fused": fused,
        "at_m_face": at(faceStats, mf), "at_m_body": at(bodyStats, thresholds.mBody),
        "at_fused": ((fused["grid"] as? [[String: Any]])?.first {
            ($0["m_body"] as? Int) == Int(thresholds.mBody)
                && (($0["T_age_bins"] as? Double) ?? .infinity) == thresholds.tAgeBins.rounded(toPlaces: 2)
        }) ?? NSNull(),
        "thresholds": thresholdsJSON(thresholds), "nfr": "NFR-F2",
    ])
}

/// SHA-256 of the rows in input order (load-path changes must leave it unchanged: "bit-identical verdicts").
func digest(_ rows: [String]) -> String {
    SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - overblock (NFR-F6)

func overblock() async {
    guard let set = args.str("set"), let labels = args.str("labels") else { die("--set DIR --labels CSV required") }
    let base = expand(set)
    let rows = readCSV(base.appending(path: labels)).compactMap { r -> (URL, String)? in
        guard let f = r["file"], let l = r["label"], l == "nsfw_adult" || l == "sfw" else { return nil }
        return (base.appending(path: f), l)
    }
    let (check, _) = makeCheck()
    // `--order reverse`: evaluate in reverse (results still reported in input order): a history-dependence probe.
    let order = args.str("order") == "reverse" ? Array(rows.indices.reversed()) : Array(rows.indices)
    let evaluated: [(String, Bool, Bool, String)] = await pmap(order.map { rows[$0] }) { url, label in
        guard let img = loadImage(url) else { return (label, false, true, "unreadable") }
        let tr = await check.evaluateDetailed(image: img)
        // Per-row fingerprint for the digest: verdict, failure and the exact score bits (no file name, no content).
        let bits = [tr.nudity, tr.nudity2].map { $0.map { String($0.bitPattern, radix: 16) } ?? "-" }.joined(separator: ",")
            + "|" + (tr.faceAges + tr.bodyOnlyAges + tr.bodyOnlyYoung).map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
        return (label, tr.verdict == .block, tr.failure != nil, "\(tr.verdict == .block ? "B" : "A")|\(tr.failure != nil)|\(bits)")
    }
    var verdicts = evaluated
    for (k, i) in order.enumerated() { verdicts[i] = evaluated[k] }
    // `--rows-out FILE`: per-row fingerprints by row index (no file names), for diffing two runs locally.
    if let f = args.str("rows-out") { try? verdicts.map(\.3).joined(separator: "\n").write(to: expand(f), atomically: true, encoding: .utf8) }
    var out: [String: Any] = ["command": "overblock", "ep": provider.rawValue, "thresholds": thresholdsJSON(thresholds),
                              "nfr": "NFR-F6", "verdicts_digest": digest(verdicts.map { $0.1 ? "B" : "A" }),
                              "scores_digest": digest(verdicts.map(\.3))]
    for label in ["nsfw_adult", "sfw"] {
        let xs = verdicts.filter { $0.0 == label }
        let blocked = xs.filter(\.1).count
        out[label] = ["n": xs.count, "blocked": blocked, "failures": xs.filter(\.2).count,
                      "withheld_rate": r4(xs.isEmpty ? nil : Double(blocked) / Double(xs.count)),
                      "bar": label == "sfw" ? 0.01 : 0.03]
    }
    writeOut(out)
}

// MARK: - preview-size (M4 review P1-3)

/// `img` rescaled so its longer side is `side` px (0 = unchanged), as a latent-projection preview of that size would be.
func rescaled(_ img: CGImage, longerSide side: Int) -> CGImage? {
    guard side > 0 else { return img }
    let s = Double(side) / Double(max(img.width, img.height))
    let w = max(1, Int((Double(img.width) * s).rounded())), h = max(1, Int((Double(img.height) * s).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// The minor branch of the rule (people → age queries → ages; `forceFullPath`, so nudity plays no part) on the
/// age-labelled, non-sexual LAGENDA scenes at preview sizes. Per side: the share of scenes whose labelled person is a
/// minor that the branch flags as having a minor, the same for adult scenes, and how often a usable face or any person
/// was found. Aggregates only (D-017: age only on non-sexual images; never combined with nudity).
func previewSize() async {
    guard let set = args.str("set"), let labels = args.str("labels") else { die("--set DIR --labels CSV required") }
    let base = expand(set)
    let sides = (args.str("sides") ?? "0,512,384,256,128").split(separator: ",").compactMap { Int($0) }
    let every = max(1, args.int("every", 1))  // every n-th row (in file order), for a bounded run
    let rows = readCSV(base.appending(path: labels)).enumerated().compactMap { i, r -> (URL, Double)? in
        guard i % every == 0, let f = r["file"], let a = r["age"].flatMap(Double.init), a >= 0 else { return nil }
        return (base.appending(path: f), a)
    }
    let (check, _) = makeCheck()
    var out: [String: Any] = ["command": "preview-size", "every": every, "ep": provider.rawValue, "n_rows": rows.count,
                              "thresholds": thresholdsJSON(thresholds), "note": "LAGENDA scenes; longer side rescaled; 0 = as stored"]
    var perSide: [[String: Any]] = []
    for side in sides {
        let res: [(Double, Bool, Bool, Bool, Bool, Int)] = await pmap(rows) { url, truth in
            guard let src = loadImage(url), let img = rescaled(src, longerSide: side) else { return (truth, false, false, false, true, 0) }
            let tr = await check.evaluateDetailed(image: img, forceFullPath: true, deadline: 30)
            return (truth, tr.minor == true, !tr.faceAges.isEmpty, !(tr.faceAges.isEmpty && tr.bodyOnlyAges.isEmpty),
                    tr.failure != nil, min(img.width, img.height))
        }
        func band(_ lo: Double, _ hi: Double) -> [(Double, Bool, Bool, Bool, Bool, Int)] { res.filter { $0.0 >= lo && $0.0 < hi } }
        func rate(_ xs: [(Double, Bool, Bool, Bool, Bool, Int)], _ f: ((Double, Bool, Bool, Bool, Bool, Int)) -> Bool) -> Any {
            r4(xs.isEmpty ? nil : Double(xs.filter(f).count) / Double(xs.count))
        }
        let le15 = band(0, 16), t1617 = band(16, 18), a1829 = band(18, 30), ge30 = band(30, 1000)
        perSide.append([
            "longer_side": side, "shorter_side_p50": r4(percentile(res.map { Double($0.5) }, 50)),
            "minor_flag_le15": rate(le15, \.1), "minor_flag_16_17": rate(t1617, \.1),
            "minor_flag_18_29": rate(a1829, \.1), "minor_flag_ge30": rate(ge30, \.1),
            "usable_face_any": rate(res, \.2), "person_any": rate(res, \.3), "failures": res.filter(\.4).count,
            "n_le15": le15.count, "n_16_17": t1617.count, "n_18_29": a1829.count, "n_ge30": ge30.count,
        ])
        FileHandle.standardError.write(Data("  side \(side) done (\(res.count) rows)\n".utf8))
    }
    out["sides"] = perSide
    writeOut(out)
}

// MARK: - probe (per-detector timing on one blank 1024² frame; no content)

func probe() {
    let img = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    let runs = args.int("runs", 20)
    // `--only freepik,mivolo,…`: probe a subset (load-time experiments).
    let only = args.str("only").map { Set($0.split(separator: ",").map(String.init)) }
    func time(_ name: String, _ load: () throws -> Any, _ run: (Any) throws -> Void) -> [String: Any] {
        if let only, !only.contains(name) { return ["model": name, "skipped": true] }
        let t0 = Date()
        guard let m = try? load() else { return ["model": name, "error": "load failed"] }
        let loadS = Date().timeIntervalSince(t0)
        let loadedMB = currentFootprintMB()
        var ts: [Double] = []
        for _ in 0..<runs {
            let s = DispatchTime.now().uptimeNanoseconds
            try? run(m)
            ts.append(Double(DispatchTime.now().uptimeNanoseconds - s) / 1e6)
        }
        return ["model": name, "load_s": r4(loadS), "p50_ms": r4(percentile(ts, 50)), "p95_ms": r4(percentile(ts, 95)),
                "footprint_loaded_mb": r4(loadedMB), "footprint_after_runs_mb": r4(currentFootprintMB())]
    }
    var out: [[String: Any]] = []
    out.append(time("freepik", { try FreepikNudity(modelDirectory: modelsDir, provider: provider, cacheDirectory: cacheDir, file: args.str("freepik-file", FreepikNudity.relativePath)!) },
                    { _ = try ($0 as! FreepikNudity).nudityScore(img) }))
    out.append(time("marqo", { try MarqoNudity(modelDirectory: modelsDir, provider: provider, cacheDirectory: cacheDir) },
                    { _ = try ($0 as! MarqoNudity).nudityScore(img) }))
    out.append(time("mivolo", { try MiVOLOAge(modelDirectory: modelsDir, provider: provider, cacheDirectory: cacheDir) },
                    { _ = try ($0 as! MiVOLOAge).age(face: img, body: img) }))
    out.append(time("vision", { VisionPeople() }, { _ = try ($0 as! VisionPeople).detect(img) }))
    out.append(time("age-bins", { try SigLIPAgeBins(modelDirectory: modelsDir) },
                    { _ = try ($0 as! SigLIPAgeBins).youngProbability(img) }))
    writeOut(["command": "probe", "ep": provider.rawValue, "freepik_file": args.str("freepik-file", FreepikNudity.relativePath)!,
              "runs": runs, "detectors": out, "peak_footprint_mb": r4(peakFootprintMB()),
              "footprint_after_mb": r4(currentFootprintMB())])
}

// MARK: - bins-check (reference comparison on content-free CC0 photos; prints per-image bins of THOSE photos only)

func binsCheck() {
    guard let dir = args.str("images") else { die("--images DIR required") }
    let files = ((try? FileManager.default.contentsOfDirectory(at: expand(dir), includingPropertiesForKeys: nil)) ?? [])
        .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(args.int("limit", 8))
    guard let bins = try? SigLIPAgeBins(modelDirectory: modelsDir) else { die("age bins load failed") }
    var rows: [[String: Any]] = []
    for f in files {
        guard let img = loadImage(f) else { continue }
        // `--raw DIR`: use the reference processor's tensor (`<file>.f32`, float32 CHW) to compare the forward alone.
        let raw = args.str("raw").flatMap { try? Data(contentsOf: expand($0).appending(path: f.lastPathComponent + ".f32")) }
        let x = raw.map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
            ?? (try! ImageTensor.chw(img, side: 224, mode: .squash, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5]))
        let t0 = DispatchTime.now().uptimeNanoseconds
        let p = try! bins.forward(image: x)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        rows.append(["file": f.lastPathComponent, "p": p.map { r4(Double($0)) }, "ms": r4(ms)])
    }
    writeOut(["command": "bins-check", "rows": rows])
}

// MARK: - stream (M5: per-preview traces of generated benign video frames; images in memory only)

func readExactly(_ n: Int) -> Data? {
    var out = Data()
    while out.count < n {
        let chunk = FileHandle.standardInput.readData(ofLength: n - out.count)
        if chunk.isEmpty { return nil }
        out.append(chunk)
    }
    return out
}

func readRecord() -> (meta: [String: Any], image: Data)? {
    func u32() -> Int? { readExactly(4).map { $0.reduce(0) { $0 << 8 | Int($1) } } }
    guard let ml = u32(), let m = readExactly(ml), let il = u32(), let img = readExactly(il) else { return nil }
    let meta = (try? JSONSerialization.jsonObject(with: m)) as? [String: Any] ?? [:]
    return (meta, img)
}

func stream() async {
    let (check, loadS) = makeCheck()
    FileHandle.standardError.write(Data("csc-bench stream: ready (load \(String(format: "%.1f", loadS)) s)\n".utf8))
    let out = FileHandle.standardOutput
    while let rec = readRecord() {
        var row = rec.meta
        guard let src = CGImageSourceCreateWithData(rec.image as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            row["error"] = "undecodable"
            out.write(try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
            continue
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let tr = await check.evaluateDetailed(image: img)
        row["ms"] = r4(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        row["verdict"] = tr.verdict == .block ? "block" : "allow"
        row["nudity"] = r4(tr.nudity)
        row["nudity2"] = r4(tr.nudity2)
        row["nude"] = tr.nude.map { $0 as Any } ?? NSNull()
        row["minor"] = tr.minor.map { $0 as Any } ?? NSNull()
        row["faces"] = tr.faceAges.count
        row["min_face_age"] = r4(tr.faceAges.min())
        row["bodies_only"] = tr.bodyOnlyAges.count
        row["min_body_age"] = r4(tr.bodyOnlyAges.min())
        row["max_young"] = r4(tr.bodyOnlyYoung.max())
        row["failure"] = tr.failure.map { "\($0)" } ?? NSNull()
        row["w"] = img.width
        row["h"] = img.height
        out.write(try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data("\n".utf8))
    }
}

extension Double {
    func rounded(toPlaces p: Int) -> Double {
        guard isFinite else { return self }
        let f = pow(10, Double(p)); return (self * f).rounded() / f
    }
}

// MARK: - load (production load path: sha256 verify + every detector, `--repeat N` fresh loads in one process)

func loadTiming() {
    // The pins are computed once, untimed (the timed load verifies them again, as the gate does).
    var sha: [String: String] = [:]
    for (key, rel) in [(ModelManifest.nudityKey, FreepikNudity.relativePath), (ModelManifest.ageKey, MiVOLOAge.relativePath),
                       (ModelManifest.ageBinsKey, SigLIPAgeBins.relativePath)] {
        sha[key] = ModelManifest.sha256Hex(of: modelsDir.appending(path: rel))
    }
    let manifest = ModelManifest.standard(modelDirectory: modelsDir, sha256: sha)
    var secs: [Double] = []
    for _ in 0..<max(1, args.int("repeat", 1)) {
        let t0 = Date()
        do {
            _ = try ChildSafetyCheck(manifest: manifest, provider: provider, cacheDirectory: cacheDir)
        } catch {
            die("manifest load failed (fail closed): \(error)")
        }
        secs.append(Date().timeIntervalSince(t0))
    }
    writeOut(["command": "load", "ep": provider.rawValue, "load_s": secs.map { r4($0) },
              "peak_footprint_mb": r4(peakFootprintMB()), "footprint_after_mb": r4(currentFootprintMB())])
}

switch args.command {
case "load": loadTiming()
case "bins-check": binsCheck()
case "probe": probe()
case "latency": await latency()
case "nudity": await nudity()
case "age": await age()
case "overblock": await overblock()
case "stream": await stream()
case "preview-size": await previewSize()
default: die("usage: csc-bench latency|nudity|age|overblock [options] (see source header)")
}
