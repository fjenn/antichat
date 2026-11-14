// The copy-deck keys by prefix (hand-written; CopyDeck.swift is generated). Used to give menu items their own
// accessibility identifiers (MenuItemIdentifiers in AntiChatUI).
public enum CopyKeys {
    public static func keys(withPrefix prefix: String) -> [String] {
        CopyDeck.english.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
