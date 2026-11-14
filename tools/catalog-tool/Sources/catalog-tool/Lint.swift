// M2.T04 step 4 (R-300 AC2, NFR-SEC2, R-239 AC1): CI gate on the emitted manifest. Fails when an assigned model is
// gated, lacks licence / attribution / modification notice, or carries a non-commercial licence without
// `noncommercial_ok: true`; when any entry ships a format other than safetensors / GGUF / Core ML / ONNX, a pickle
// or a `trust_remote_code` Python file; when a source is not an HF commit URL; and when an Evil chat pick leaves
// its tier's Normal family/template without `evil_family_reason`.
import Foundation

enum Lint {
    static let formats: Set<String> = ["mlx-safetensors", "safetensors", "gguf", "mlmodelc", "mlpackage", "onnx"]
    /// An anonymous commit-pinned URL: Hugging Face (D-007), or GitHub raw for an upstream that is only there
    /// (A-M0-T07a (e): TAEHV; M5 review P1-1).
    static let sourcePattern = "^https://(huggingface\\.co/[^/]+/[^/]+/resolve|raw\\.githubusercontent\\.com/[^/]+/[^/]+)/[0-9a-f]{40}/"

    /// Pickle / executable code. `.bin` is allowed only inside a compiled Core ML bundle (`weights/weight.bin`,
    /// `coremldata.bin` are Core ML's own containers, not pickle) or when the entry declares it a raw tensor file.
    static func forbiddenFile(_ path: String, rawTensors: [String] = []) -> String? {
        let lower = path.lowercased()
        for ext in [".py", ".pt", ".pth", ".pkl", ".pickle", ".ckpt", ".h5"] where lower.hasSuffix(ext) { return ext }
        if lower.hasSuffix(".bin"), !(lower.contains(".mlmodelc/") || lower.contains(".mlpackage/")),
           !rawTensors.contains(where: { globMatch($0, path) }) { return ".bin" }
        return nil
    }

    static func isNonCommercial(_ license: String) -> Bool {
        let l = license.lowercased()
        return l.contains("-nc") || l.contains("noncommercial") || l.contains("non-commercial")
    }

    /// Every model id a cell installs (chat picks + step-downs, roles, packs) and their `requires` closure.
    static func assigned(_ m: Manifest) -> Set<String> {
        var ids = Set<String>()
        for classes in m.assignments.values {
            for c in classes.values {
                for p in [c.chat.normal, c.chat.evil].compactMap({ $0 }) { ids.insert(p.model); p.step_down.map { ids.insert($0) } }
                ids.insert(c.chat.fast_first)
                for r in [c.embed, c.rerank, c.stt_multi, c.csam_check, c.cite_check].compactMap({ $0 }) { ids.insert(r) }
                for p in [c.voice, c.photo, c.video].compactMap({ $0 }) { ids.formUnion(p.normal); ids.formUnion(p.evil) }
            }
        }
        var queue = Array(ids)
        while let id = queue.popLast() {
            for r in m.models[id]?.requires ?? [] where ids.insert(r).inserted { queue.append(r) }
        }
        return ids
    }

    static func run(_ m: Manifest, gated: [String: Bool]) -> [String] {
        var errors: [String] = []
        if m.schema != 2 { errors.append("schema must be 2") }
        for (id, e) in m.models.sorted(by: { $0.key < $1.key }) {
            if !formats.contains(e.format) { errors.append("\(id): format \(e.format) not allowed (NFR-SEC2)") }
            if e.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) == nil { errors.append("\(id): commit is not a 40-char sha") }
            for f in e.files {
                if let ext = forbiddenFile(f.path, rawTensors: e.raw_tensor_files ?? []) { errors.append("\(id): \(f.path) is \(ext) (pickle / trust_remote_code, NFR-SEC2)") }
                if f.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil { errors.append("\(id): \(f.path) has no sha256") }
                if f.sources.isEmpty { errors.append("\(id): \(f.path) has no source") }
                for s in f.sources where s.range(of: sourcePattern, options: .regularExpression) == nil {
                    errors.append("\(id): source \(s) is not a commit-pinned HF / GitHub raw URL (D-007)")
                }
            }
            for r in e.requires ?? [] where m.models[r] == nil { errors.append("\(id): requires unknown \(r)") }
        }
        for id in assigned(m).sorted() {
            guard let e = m.models[id] else { errors.append("assignment names unknown model \(id)"); continue }
            if gated[id] != false { errors.append("\(id): gated or unresolved (R-300 AC1)") }
            if (e.license ?? "").isEmpty { errors.append("\(id): no license (R-300 AC2)") }
            if (e.license_url ?? "").isEmpty { errors.append("\(id): no license_url (R-300 AC2)") }
            if (e.attribution ?? "").isEmpty { errors.append("\(id): no attribution (R-300 AC2)") }
            if (e.modification_notice ?? "").isEmpty { errors.append("\(id): no modification_notice (R-300 AC2)") }
            if let l = e.license, isNonCommercial(l), !e.noncommercial_ok {
                errors.append("\(id): non-commercial license \(l) without noncommercial_ok (R-300 AC2)")
            }
        }
        errors += runtimeErrors(m.runtimes ?? [])
        for (key, classes) in m.assignments.sorted(by: { $0.key < $1.key }) {
            for (sc, c) in classes.sorted(by: { $0.key < $1.key }) {
                let at = "\(key)/\(sc)"
                if !c.title.hasPrefix("@"), m.models[c.title] == nil { errors.append("\(at): title \(c.title) unknown") }
                if c.title.hasPrefix("@"), !["@chat", "@chat_fast"].contains(c.title) { errors.append("\(at): bad title alias \(c.title)") }
                if c.chat.normal == nil, c.chat.normal_reason == nil { errors.append("\(at): chat.normal needs a model or normal_reason") }
                if c.chat.evil == nil, c.chat.evil_reason == nil { errors.append("\(at): chat.evil needs a model or evil_reason") }
                if c.embed == nil, c.embed_reason == nil { errors.append("\(at): embed needs a model or embed_reason") }
                if c.rerank == nil, c.rerank_reason == nil { errors.append("\(at): rerank needs a model or rerank_reason") }
                if c.csam_check == nil, c.csam_check_reason == nil { errors.append("\(at): csam_check needs a model or reason") }
                for (name, slot, reason) in [("voice", c.voice, c.voice_reason), ("photo", c.photo, c.photo_reason), ("video", c.video, c.video_reason)]
                where slot == nil && reason == nil { errors.append("\(at): \(name) needs models or \(name)_reason") }
                if let p = c.photo, p.evil != p.normal { errors.append("\(at): Evil photo must use the Normal ids (Q-009 a)") }
                if let p = c.video, p.evil != p.normal { errors.append("\(at): Evil video must use the Normal ids (Q-009 a)") }
                if let e = c.chat.evil {
                    for id in [e.model, e.step_down].compactMap({ $0 }) where id == c.chat.fast_first {
                        errors.append("\(at): Evil chat may never use chat_fast (R-227)")
                    }
                    if let n = c.chat.normal, c.chat.evil_family_reason == nil {
                        let em = m.models[e.model], nm = m.models[n.model]
                        if em?.family == nil || em?.family != nm?.family || em?.chat_template != nm?.chat_template {
                            errors.append("\(at): Evil \(e.model) is not the family/template of \(n.model) and has no evil_family_reason (R-239 AC1)")
                        }
                    }
                }
            }
        }
        return errors
    }

    /// M6.T16: runtime components (catalog `runtimes[]`). Generic rules only; nothing media-specific.
    static let tiers: Set<String> = ["T0", "T1", "T2", "T3", "T4"]
    static func runtimeErrors(_ list: [RuntimeEntry]) -> [String] {
        var errors: [String] = []
        for r in list {
            let at = "runtime \(r.name)"
            if r.name.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) == nil { errors.append("\(at): name must be lowercase [a-z0-9-]") }
            if r.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) == nil { errors.append("\(at): version must be x.y.z") }
            if r.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil { errors.append("\(at): sha256 must be 64 hex") }
            if r.size_bytes <= 0 { errors.append("\(at): size_bytes must be > 0") }
            if r.url.range(of: "^https?://", options: .regularExpression) == nil { errors.append("\(at): url must be http(s)") }
            if !r.url.hasSuffix(".zip") { errors.append("\(at): url must name a .zip") }
            if r.tiers.isEmpty || !Set(r.tiers).isSubset(of: tiers) { errors.append("\(at): tiers must be a non-empty subset of T0…T4") }
            if !["adhoc", "dev", "devid"].contains(r.signature_mode) { errors.append("\(at): signature_mode must be adhoc|dev|devid") }
        }
        return errors
    }
}
