//
//  PromptManifest.swift
//  osaurus
//
//  Data types for structured system prompt composition.
//  PromptSection represents one logical block; PromptManifest is the
//  assembled snapshot used for token accounting, cache hashing, and debug.
//

import CryptoKit
import Foundation

// MARK: - PromptSectionID

/// Stable IDs for sections that other proof and budget paths inspect by name.
public enum PromptSectionID {
    public static let platform = "platform"
    public static let persona = "persona"
    public static let memory = "memory"
}

// MARK: - PromptSection

/// One logical block of the system prompt (e.g. base identity, sandbox, memory).
public struct PromptSection: Sendable {

    public let id: String
    public let label: String
    public let content: String
    public let cacheability: Cacheability

    public enum Cacheability: String, Sendable {
        /// Stable across requests — safe for prefix cache reuse.
        case `static`
        /// Changes per request (memory, RAG, skills).
        case dynamic
    }

    /// Precomputed at init: `content` is immutable, and these are read from
    /// SwiftUI body evaluation (context budget popover) on every render.
    /// Recomputing the whitespace trim per read was an O(n) main-thread
    /// cost that showed up as app hangs with large system prompts.
    public let estimatedTokens: Int
    public let isEmpty: Bool

    public init(id: String, label: String, content: String, cacheability: Cacheability) {
        self.id = id
        self.label = label
        self.content = content
        self.cacheability = cacheability
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.estimatedTokens = TokenEstimator.estimate(trimmed)
        self.isEmpty = trimmed.isEmpty
    }

    public static func `static`(id: String, label: String, content: String) -> PromptSection {
        PromptSection(id: id, label: label, content: content, cacheability: .static)
    }

    public static func dynamic(id: String, label: String, content: String) -> PromptSection {
        PromptSection(id: id, label: label, content: content, cacheability: .dynamic)
    }
}

// MARK: - PromptManifest

/// Snapshot of the assembled system prompt — single source of truth for
/// token accounting, prefix cache hashing, and debug inspection.
public struct PromptManifest: Sendable {

    public let sections: [PromptSection]

    /// A manifest with no sections, used as a cheap placeholder before the
    /// preview composition has run (or while it is deferred behind a storage
    /// rotation) so the budget popover can render the message overlay without
    /// blocking on the agent DB.
    public static let empty = PromptManifest(sections: [])

    // ANTICHAT-PATCH: UP-OS-038 public init (the composer that built manifests, SystemPromptComposer, is not vendored; AntiChatHarness.PromptComposer builds them)
    public init(sections: [PromptSection]) {
        self.sections = sections
    }
    // ANTICHAT-PATCH-END

    public var totalEstimatedTokens: Int {
        sections.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Tokens covered by static sections before the first dynamic section.
    public var staticPrefixTokens: Int {
        var tokens = 0
        for section in sections {
            if section.cacheability == .dynamic { break }
            tokens += section.estimatedTokens
        }
        return tokens
    }

    /// Hash of the static prefix content only (debug display without tools).
    public var prefixHash: String {
        staticPrefixHash(toolNames: [])
    }

    /// Tokens from sections that are NOT the memory section.
    public var systemPromptTokens: Int {
        sections.filter { $0.id != PromptSectionID.memory }.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// Tokens from the memory section specifically.
    public var memoryTokens: Int {
        section(PromptSectionID.memory)?.estimatedTokens ?? 0
    }

    public func section(_ id: String) -> PromptSection? {
        sections.first { $0.id == id }
    }

    /// Rendered content of only the static sections (before the first dynamic section).
    public var staticPrefixContent: String {
        var parts: [String] = []
        for section in sections {
            if section.cacheability == .dynamic { break }
            let trimmed = section.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Legacy hash of static prefix content + tool names. Internal: the only
    /// caller is the empty-array `prefixHash` debug accessor above.
    func staticPrefixHash(toolNames: [String]) -> String {
        PromptPrefixHasher.hash(systemContent: staticPrefixContent, toolNames: toolNames)
    }

    // ANTICHAT-PATCH: UP-OS-029 strip the [Tool] (Osaurus OpenAI wire type) overloads and ComposedContext (SystemPromptComposer output; the composer is ported in M1 G-007)
    // ANTICHAT-PATCH-END

    public var debugDescription: String {
        var lines: [String] = ["[Context Manifest]"]
        for (i, section) in sections.enumerated() {
            let tokens = section.estimatedTokens
            guard tokens > 0 else { continue }
            let num = String(format: "%2d", i + 1)
            let name = section.label.padding(toLength: 20, withPad: " ", startingAt: 0)
            let tok = String(format: "%5d", tokens)
            let cache = section.cacheability.rawValue
            lines.append("  \(num)  \(name) \(tok)  \(cache)")
        }
        lines.append("  " + String(repeating: "\u{2500}", count: 38))
        lines.append("  Total:               \(String(format: "%5d", totalEstimatedTokens))")
        let hash = prefixHash.prefix(16)
        lines.append("  Static prefix:       \(String(format: "%5d", staticPrefixTokens)) (hash: \(hash))")
        return lines.joined(separator: "\n")
    }

    public func systemPromptInjectionTrace(expectedPrompt: String) -> SystemPromptInjectionTrace {
        return systemPromptInjectionTrace(
            expectedPrompt: expectedPrompt,
            renderedPrompt: PromptRenderer.render(sections)
        )
    }

    public func systemPromptInjectionTrace(
        expectedPrompt: String,
        renderedPrompt: String
    ) -> SystemPromptInjectionTrace {
        let expected = expectedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else {
            return SystemPromptInjectionTrace(expectedPromptWasEmpty: true)
        }

        let matchingSectionIds = sections.compactMap { section in
            section.content.contains(expected) ? section.id : nil
        }

        return SystemPromptInjectionTrace(
            expectedPromptWasEmpty: false,
            matchingSectionIds: matchingSectionIds,
            staticPrefixContainsExpectedPrompt: staticPrefixContent.contains(expected),
            renderedPromptContainsExpectedPrompt: renderedPrompt.contains(expected),
            memorySectionContainsExpectedPrompt: section(PromptSectionID.memory)?.content.contains(expected) == true
        )
    }
}

/// Source-level evidence that a configured agent prompt reached the static
/// system prompt surface. This does not prove a model obeyed the prompt; it
/// only proves the composer handed the expected text to the runtime path.
public struct SystemPromptInjectionTrace: Sendable, Equatable {
    public let expectedPromptWasEmpty: Bool
    public let matchingSectionIds: [String]
    public let staticPrefixContainsExpectedPrompt: Bool
    public let renderedPromptContainsExpectedPrompt: Bool
    public let memorySectionContainsExpectedPrompt: Bool

    public init(
        expectedPromptWasEmpty: Bool = false,
        matchingSectionIds: [String] = [],
        staticPrefixContainsExpectedPrompt: Bool = false,
        renderedPromptContainsExpectedPrompt: Bool = false,
        memorySectionContainsExpectedPrompt: Bool = false
    ) {
        self.expectedPromptWasEmpty = expectedPromptWasEmpty
        self.matchingSectionIds = matchingSectionIds
        self.staticPrefixContainsExpectedPrompt = staticPrefixContainsExpectedPrompt
        self.renderedPromptContainsExpectedPrompt = renderedPromptContainsExpectedPrompt
        self.memorySectionContainsExpectedPrompt = memorySectionContainsExpectedPrompt
    }

    public var personaSectionContainsExpectedPrompt: Bool {
        matchingSectionIds.contains(PromptSectionID.persona)
    }

    public var passed: Bool {
        !expectedPromptWasEmpty
            && personaSectionContainsExpectedPrompt
            && staticPrefixContainsExpectedPrompt
            && renderedPromptContainsExpectedPrompt
    }

    public var reasonCodes: [String] {
        var codes: [String] = []
        if expectedPromptWasEmpty {
            codes.append("empty_expected_prompt")
        }
        codes.append(
            personaSectionContainsExpectedPrompt
                ? "present_in_persona_section"
                : "missing_persona_section"
        )
        codes.append(
            staticPrefixContainsExpectedPrompt
                ? "present_in_static_prefix"
                : "missing_static_prefix"
        )
        codes.append(
            renderedPromptContainsExpectedPrompt
                ? "present_in_rendered_prompt"
                : "missing_rendered_prompt"
        )
        if memorySectionContainsExpectedPrompt {
            codes.append("present_in_memory_section")
        }
        return codes
    }
}

enum PromptRenderer {
    static func render(_ sections: [PromptSection]) -> String {
        sections
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

enum PromptPrefixHasher {
    static func hash(systemContent: String, toolNames: [String]) -> String {
        let tools = toolNames.sorted().joined(separator: "\0")
        let combined = systemContent + "\0" + tools
        return digest(Data(combined.utf8))
    }

    // ANTICHAT-PATCH: UP-OS-029 (hash over [Tool])
    // ANTICHAT-PATCH-END

    private static func digest(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// ANTICHAT-PATCH: UP-OS-029 (ComposedContext)
// ANTICHAT-PATCH-END
