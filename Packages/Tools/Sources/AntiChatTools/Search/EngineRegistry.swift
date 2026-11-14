// M7.T01 step 4 (R-248 AC2): the engines this build compiles and the enabled set. Defaults: DuckDuckGo, Brave,
// Mojeek, Startpage, Wikipedia; Bing compiled but disabled; no Google engine exists in code (the vendored
// `google_cse` provider definition is never instantiated: there is no provider path in v1, M7.T04 → M11).
import AntiChatFoundation
import Foundation
import os

public final class EngineRegistry: @unchecked Sendable {
    public static let shared = EngineRegistry()
    public static let didChange = Notification.Name("AntiChatEngineRegistryDidChange")

    /// Code defaults, in fallback order (HTML engines race; declarative engines are the fallback tier).
    public static let defaults: [SearchEngineConfig] = [
        OsaurusEngines.duckduckgo, OsaurusEngines.brave, MojeekEngine.config, StartpageEngine.config,
    ] + [WikipediaDefinition.config].compactMap { $0 } + [OsaurusEngines.bing]

    /// Every engine id compiled into this build (AT-248 c2: none matches `google`).
    public static var allCompiled: [String] { defaults.map(\.id) }

    private let state: OSAllocatedUnfairLock<[SearchEngineConfig]>
    public let appVersion: String

    public init(configs: [SearchEngineConfig] = EngineRegistry.defaults,
                appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") {
        state = OSAllocatedUnfairLock(initialState: configs)
        self.appVersion = appVersion
    }

    public var configs: [SearchEngineConfig] { state.withLock { $0 } }
    /// Ids of the enabled engines, in order.
    public var enabled: [String] { configs.filter(\.enabled).map(\.id) }
    public var enabledEngines: [WebSearchEngine] { configs.filter(\.enabled).map(WebSearchEngine.init) }
    /// Display names for the consent sheet (`search.consent.body` {engines}).
    public var enabledNames: [String] { configs.filter(\.enabled).map(\.name) }
    /// Hosts the enabled engines contact (the proxy test's allow-list).
    public var enabledHosts: Set<String> { Set(configs.filter(\.enabled).compactMap(\.host)) }

    /// Applies a verified catalog document (R-253): returns true when the configuration changed. Malformed section →
    /// unchanged (last good). A catalog without the section restores nothing and keeps the current set.
    @discardableResult
    public func apply(catalogJSON data: Data?) -> Bool {
        guard let data, let section = try? CatalogEngineConfig.section(fromCatalog: data) else { return false }
        let merged = CatalogEngineConfig.merge(defaults: Self.defaults, overrides: section, appVersion: appVersion)
        let changed = state.withLock { s -> Bool in
            guard s != merged else { return false }
            s = merged
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changed
    }
}

/// `Resources/search/WikipediaEngine.json`, executed by the vendored DeclarativeSearchBackend mapper (P-files-tools-11).
public enum WikipediaDefinition {
    /// Nil only for a broken build (resource missing): Wikipedia is then absent from the set and the error is logged.
    public static let config: SearchEngineConfig? = {
        guard let url = Bundle.module.url(forResource: "WikipediaEngine", withExtension: "json", subdirectory: "search"),
              let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(SearchEngineConfig.self, from: data) else {
            AppLog.log(.tools, .error, "search: WikipediaEngine.json missing or invalid in the AntiChatTools bundle")
            return nil
        }
        return c
    }()
}
