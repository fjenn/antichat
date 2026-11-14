// M2 rollback flags (M2 card "FeatureFlags.swift"; created by M2.T11). Each risky M2 behaviour can be switched off
// without a rebuild: `defaults write <suite> ff.<name> -bool NO`, or `-ff.<name> NO` on the command line (the
// argument domain wins). All default on.
import Foundation

public enum FeatureFlag: String, Sendable, CaseIterable {
    case autoModelUpdates, mediaStepAside, powerPolicy, warmSecondVariant, semanticSearch, evilMode, starterHandoff, preRouter,
         fallbackIntentCheck,
         /// M8.T02: topic memory (tool + frozen snapshot); off = tool not offered, no snapshot.
         memory,
         /// M8.T04: projects (sidebar rows, pages, instructions, files); off hides them (chats keep project_id).
         projects,
         /// M8.T05: project retrieval above 30 % of the context; off = whole files up to the context with a
         /// truncation notice (rollback).
         projectRetrieval,
         /// M8.T06: Import from ChatGPT or Claude (Settings row, File menu); off hides the entry points.
         importChats,
         /// M8.T07: Export all data (Settings row, File menu) and the single-chat Share menu; off hides them.
         exportAll,
         /// M8.T09: the crash prompt (Export logs stays: it is local); off = no prompt, no MetricKit subscriber.
         diagnostics,
         /// M8.T10: Settings › Storage dashboard (bar, model rows, Models folder, Clean up, Remove everything); off =
         /// the M2 Capabilities rows only (the Storage page shows its placeholder).
         storageDashboard,
         /// M8.T11: AntiChat › Uninstall AntiChat… (off hides the menu item; the Storage row stays).
         uninstall,
         /// M8.T12: notifications (answer, picture, video, download, update); off = no requests at all (the quit
         /// guard for a running video stays).
         notifications,
         /// M8.T13: the menu bar item (off removes it whatever the Settings toggle says).
         menuBar,
         /// M8.T13: the global quick panel (off = no hotkey registered, no panel).
         quickPanel,
         /// M3.T11: the VoiceButton (spoken conversation); off hides it (rollback of M3.T09–T11; dictation and read
         /// aloud stay).
         voiceConversation,
         /// M10.T02: Move to Applications (LetsMove) at launch from a DMG / Downloads; off = never offered.
         moveToApplications

    public var defaultsKey: String { "ff.\(rawValue)" }

    public func isEnabled(_ defaults: UserDefaults = AppDefaults.standard) -> Bool {
        guard let v = defaults.object(forKey: defaultsKey) else { return true }
        if let b = v as? Bool { return b }
        if let s = v as? String { return (s as NSString).boolValue }
        return true
    }
}
