//
//  CommandPaletteQueryEnvironment.swift
//  CommandPaletteKit
//

import SwiftUI

private struct CommandPaletteQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    /// The active palette search query. Built-in rows read this to highlight fuzzy matches.
    public var commandPaletteQuery: String {
        get { self[CommandPaletteQueryKey.self] }
        set { self[CommandPaletteQueryKey.self] = newValue }
    }
}
// ANTICHAT-PATCH: UP-CP-001 host hooks: the host observes the query (its own providers and tabs), takes Tab and
// owns dismissal (an in-window overlay has no DismissAction to call).
/// Callbacks a host installs with ``SwiftUI/View/commandPaletteHostHooks(_:)``. Every hook is optional; a `nil`
/// hook keeps upstream behaviour.
public struct CommandPaletteHostHooks: Sendable {
    /// Called with the query on appear and after every change.
    public var queryDidChange: (@MainActor @Sendable (String) -> Void)?
    /// Called for Tab with the current query; return `true` to consume it (no tab completion).
    public var tabAction: (@MainActor @Sendable (String) -> Bool)?
    /// Replaces `DismissAction` for Escape and after a row is activated.
    public var dismiss: (@MainActor @Sendable () -> Void)?

    public init(
        queryDidChange: (@MainActor @Sendable (String) -> Void)? = nil,
        tabAction: (@MainActor @Sendable (String) -> Bool)? = nil,
        dismiss: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.queryDidChange = queryDidChange
        self.tabAction = tabAction
        self.dismiss = dismiss
    }
}

/// Holds the hooks read during `body`, for the escaping callbacks (key monitor, submit, tap) that run after it.
@MainActor
final class CommandPaletteHostHooksBox {
    var hooks = CommandPaletteHostHooks()
}

private struct CommandPaletteHostHooksKey: EnvironmentKey {
    static let defaultValue = CommandPaletteHostHooks()
}

extension EnvironmentValues {
    public var commandPaletteHostHooks: CommandPaletteHostHooks {
        get { self[CommandPaletteHostHooksKey.self] }
        set { self[CommandPaletteHostHooksKey.self] = newValue }
    }
}

extension View {
    /// Installs host callbacks for query changes, Tab and dismissal.
    public func commandPaletteHostHooks(_ hooks: CommandPaletteHostHooks) -> some View {
        environment(\.commandPaletteHostHooks, hooks)
    }
}
// ANTICHAT-PATCH-END

// ANTICHAT-PATCH: UP-CP-005 the result list's spoken name (a host string: the kit carries no localised copy)
private struct CommandPaletteResultsLabelKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The spoken name of the result list; an unnamed list is an "Element has no description" in the audit.
    public var commandPaletteResultsLabel: String? {
        get { self[CommandPaletteResultsLabelKey.self] }
        set { self[CommandPaletteResultsLabelKey.self] = newValue }
    }
}

extension View {
    /// Names the result list for VoiceOver.
    public func commandPaletteResultsLabel(_ label: String) -> some View {
        environment(\.commandPaletteResultsLabel, label)
    }
}

/// The result list as a named group, when the host named it.
struct PaletteResultsAccessibility: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .contain).accessibilityLabel(Text(label))
        } else {
            content
        }
    }
}
// ANTICHAT-PATCH-END

// ANTICHAT-PATCH: UP-CP-006 the search field's accessibility identifier (a host string)
private struct CommandPaletteFieldIdentifierKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The accessibility identifier of the search field (UI tests query and click the field itself).
    public var commandPaletteFieldIdentifier: String? {
        get { self[CommandPaletteFieldIdentifierKey.self] }
        set { self[CommandPaletteFieldIdentifierKey.self] = newValue }
    }
}

extension View {
    /// Names the search field. An identifier on the whole palette view made its centre (a result row) the click
    /// target of "the field", so a UI test's click activated a row and closed the palette.
    public func commandPaletteFieldIdentifier(_ id: String) -> some View {
        environment(\.commandPaletteFieldIdentifier, id)
    }
}

/// The search field's identifier, when the host set one.
struct PaletteFieldIdentifier: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}
// ANTICHAT-PATCH-END
