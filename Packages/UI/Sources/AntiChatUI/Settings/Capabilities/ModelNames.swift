// VQ (S-21 Capabilities › Advanced, Storage): what a person reads for a model — its published name ("Qwen3.5-9B",
// "Parakeet", "FLUX.2 [klein] 4B", taken from the catalog's attribution line, the part before "©") and its precision
// ("4-bit", "16-bit"), never the catalog key ("img-klein-q4") or the raw quant ("Q4_0", "fp16").
import AntiChatPlatform
import Foundation

enum ModelNames {
    /// The model's published name; the catalog key only when the catalog has none.
    static func name(_ id: String, catalog: ModelCatalog? = CatalogLaunch.shared?.catalog) -> String {
        guard let a = catalog?.models[id]?.attribution, let r = a.range(of: "©") else { return id }
        let n = a[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? id : n
    }

    /// The picker's label per model id: its published name, plus " · {precision}" when another option shares that
    /// name (chat-9b-q4 and chat-9b-q8 are both "Qwen3.5-9B"; two identical menu items could not be told apart).
    static func pickerLabels(_ options: [(id: String, quant: String?)], name: (String) -> String) -> [String: String] {
        let names = Dictionary(options.map { ($0.id, name($0.id)) }, uniquingKeysWith: { a, _ in a })
        var count: [String: Int] = [:]
        for o in options { count[names[o.id] ?? o.id, default: 0] += 1 }
        var out: [String: String] = [:]
        for o in options {
            let n = names[o.id] ?? o.id
            if count[n, default: 0] > 1, let p = precision(o.quant) { out[o.id] = "\(n) · \(p)" } else { out[o.id] = n }
        }
        return out
    }

    /// "4bit" / "Q4_0" / "Q4_K_M" → "4-bit"; "fp16" / "bf16" / "f16" → "16-bit"; anything else as is.
    static func precision(_ quant: String?) -> String? {
        guard let q = quant?.lowercased(), !q.isEmpty else { return nil }
        let digits: String
        if q.hasPrefix("q") {
            digits = String(q.dropFirst().prefix { $0.isNumber })
        } else if q.hasPrefix("fp") || q.hasPrefix("bf") {
            digits = String(q.dropFirst(2).prefix { $0.isNumber })
        } else if q.hasPrefix("f") || q.hasPrefix("int") {
            digits = String(q.drop { !$0.isNumber }.prefix { $0.isNumber })
        } else {
            digits = String(q.prefix { $0.isNumber })
        }
        return digits.isEmpty ? quant : "\(digits)-bit"
    }
}
