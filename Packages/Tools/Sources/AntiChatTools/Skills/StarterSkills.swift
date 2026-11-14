// M7.T12 step 7 (R-082 AC5): the five starter skills (instruction-only SKILL.md, no scripts) bundled in
// `Resources/StarterSkills/<name>/`. They are copied into the Skills folder once, on the first launch of a build that
// has skills, as ordinary editable folders (trust `bundled`); meeting-notes and email-polish start on
// [ASSUMPTION per blueprint B3.1 item 7], the other three off. A starter the user deletes is not brought back
// (the marker file `.starter-skills-v1` records that the copy ran).
import Foundation

public enum StarterSkills {
    public static let names = ["meeting-notes", "email-polish", "study-flashcards", "trip-planner", "recipe-scaler"]
    public static let onByDefault: Set<String> = ["meeting-notes", "email-polish"]
    static let marker = ".starter-skills-v1"

    /// The bundled folder of starter `name`.
    public static func bundledFolder(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "StarterSkills")
    }

    /// Copies the starters into `store` unless that already happened. Returns the names installed now.
    @discardableResult
    public static func installIfNeeded(into store: SkillStore) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
        let markerURL = store.root.appendingPathComponent(marker)
        guard !fm.fileExists(atPath: markerURL.path) else { return [] }
        var installed: [String] = []
        for name in names {
            guard let src = bundledFolder(name), store.skill(named: name) == nil,
                  !fm.fileExists(atPath: store.directory(for: name).path) else { continue }
            let stage = fm.temporaryDirectory.appendingPathComponent("antichat-starter-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: stage) }
            try SkillStore.copyTree(from: src, to: stage)
            try store.install(from: stage, name: name, trust: .bundled, enabled: onByDefault.contains(name), replacing: false)
            installed.append(name)
        }
        try Data("1\n".utf8).write(to: markerURL)
        return installed
    }
}
