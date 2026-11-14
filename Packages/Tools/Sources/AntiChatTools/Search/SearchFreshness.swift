// M7.T16 review #11 (M7.T03 step 3 schema `web_search {queries, freshness, category}`): the model's time filter rides
// on each engine's own date parameter (the ddgs/searxng values for the keyless pages): DuckDuckGo `df=d|w|m`, Brave
// `tf=pd|pw|pm`, Startpage `with_date=d|w|m`. Mojeek and Wikipedia have no keyless date filter and get nothing.
// `category: news` with no freshness asks for the past week (ddgs' news search is a separate endpoint; the plain
// result pages are kept and filtered by date instead). A user-facing parameter only, never a content check (R-241).
import Foundation

public enum SearchFreshness {
    /// The effective filter: `day`, `week`, `month`, or nil (any time).
    public static func effective(freshness: String?, category: String?) -> String? {
        switch freshness {
        case "day", "week", "month": freshness
        case "any": nil
        default: category == "news" ? "week" : nil
        }
    }

    /// The engine's date parameter for `freshness` (nil = none for this engine or any time).
    public static func parameter(engine: String, freshness: String?) -> URLQueryItem? {
        guard let f = freshness, let i = ["day", "week", "month"].firstIndex(of: f) else { return nil }
        switch engine {
        case "duckduckgo": return URLQueryItem(name: "df", value: ["d", "w", "m"][i])
        case "brave": return URLQueryItem(name: "tf", value: ["pd", "pw", "pm"][i])
        case "startpage": return URLQueryItem(name: "with_date", value: ["d", "w", "m"][i])
        default: return nil
        }
    }
}
