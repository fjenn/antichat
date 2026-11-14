// M6.T09 step 4 (R-273 AC2): the JSON Schema checker for file-out specs (draft 2020-12 subset: type incl. the BFCL
// aliases dict/float/tuple, properties, required, additionalProperties: false, enum, const, minimum/maximum,
// minLength/maxLength, minItems/maxItems, items, anyOf, oneOf). It is also the tool loop's argument checker (Harness
// `ToolSchemaCheck` delegates here), so "malformed" means the same for every tool. The create_* tools add semantic
// checks on top (`FileOutSpecs.problems`); any problem → the one repair turn (`RepairRetry`, M1.T16), a second
// failure → the error card (`file.createFailed` + [Try again]).
import Foundation

public enum SpecValidator {
    /// Problems of `value` against `schema` (empty = valid). Paths are JSONPath-like (`$.sheets[0].name`).
    public static func problems(_ value: Any, _ schema: [String: Any], path: String = "$") -> [String] {
        var out: [String] = []
        if let any = schema["anyOf"] as? [[String: Any]] {
            if !any.contains(where: { problems(value, $0, path: path).isEmpty }) { out.append("\(path): matches no anyOf branch") }
        }
        if let one = schema["oneOf"] as? [[String: Any]] {
            let n = one.filter { problems(value, $0, path: path).isEmpty }.count
            if n != 1 { out.append("\(path): matches \(n) oneOf branches (exactly one needed)") }
        }
        if let c = schema["const"], !equal(c, value) { out.append("\(path): ≠ const") }
        if let e = schema["enum"] as? [Any], !e.contains(where: { equal($0, value) }) {
            let allowed = e.map { "\($0)" }.joined(separator: ", ")
            out.append("\(path): not one of [\(allowed)]")
        }
        if let t = schema["type"] {
            let types = (t as? [String]) ?? [(t as? String) ?? ""]
            if !types.contains(where: { matches(value, type: $0) }) {
                out.append("\(path): not \(types.joined(separator: "|"))")
                return out
            }
        }
        if let n = number(value) {
            if let lo = (schema["minimum"] as? NSNumber)?.doubleValue, n < lo { out.append("\(path): < minimum \(fmt(lo))") }
            if let hi = (schema["maximum"] as? NSNumber)?.doubleValue, n > hi { out.append("\(path): > maximum \(fmt(hi))") }
        }
        if let s = value as? String {
            if let lo = (schema["minLength"] as? NSNumber)?.intValue, s.count < lo { out.append("\(path): shorter than \(lo) characters") }
            if let hi = (schema["maxLength"] as? NSNumber)?.intValue, s.count > hi { out.append("\(path): longer than \(hi) characters") }
        }
        if let obj = value as? [String: Any] {
            let props = schema["properties"] as? [String: Any] ?? [:]
            for r in schema["required"] as? [String] ?? [] where obj[r] == nil { out.append("\(path).\(r): required") }
            for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
                if let ps = props[k] as? [String: Any] {
                    out += problems(v, ps, path: "\(path).\(k)")
                } else if (schema["additionalProperties"] as? Bool) == false {
                    out.append("\(path).\(k): not allowed")
                } else if let extra = schema["additionalProperties"] as? [String: Any] {
                    out += problems(v, extra, path: "\(path).\(k)")
                }
            }
        }
        if let arr = value as? [Any] {
            if let lo = (schema["minItems"] as? NSNumber)?.intValue, arr.count < lo { out.append("\(path): fewer than \(lo) items") }
            if let hi = (schema["maxItems"] as? NSNumber)?.intValue, arr.count > hi { out.append("\(path): more than \(hi) items (\(arr.count))") }
            if let items = schema["items"] as? [String: Any] {
                for (i, v) in arr.enumerated() { out += problems(v, items, path: "\(path)[\(i)]") }
            }
        }
        return out
    }

    /// Problems of the JSON text `json` against the JSON schema text `schemaJSON`.
    public static func problems(json: String, schemaJSON: String) -> [String] {
        guard let v = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) else {
            return ["$: not valid JSON"]
        }
        let s = (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any] ?? [:]
        return problems(v, s)
    }

    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    public static func number(_ v: Any) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    public static func matches(_ v: Any, type: String) -> Bool {
        switch type {
        case "object", "dict": return v is [String: Any]
        case "array", "tuple", "list": return v is [Any]
        case "string": return v is String
        case "boolean", "bool":
            if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() }
            return false
        case "integer", "int":
            guard let d = number(v) else { return false }
            return d == d.rounded()
        case "number", "float", "double": return number(v) != nil
        case "null": return v is NSNull
        case "", "any", "Any": return true
        default: return true
        }
    }

    public static func equal(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject).map { $0.isEqual(b) } ?? false
    }
}
