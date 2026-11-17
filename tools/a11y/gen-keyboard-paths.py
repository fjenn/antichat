#!/usr/bin/env python3
"""Generates tools/a11y/keyboard-paths.yml (M9.T01 step 4; NFR-A3). Run with `python3 -I`; `--check` fails when stale.

Every user function → its keyboard-only path (no pointer) and the accessibility identifier that proves it worked:
  * the fixed app/chat/composer paths below (menus, shortcuts from ShortcutNames.swift, composer, message actions,
    versions, sheets, onboarding, palette);
  * one entry per Settings row in SettingsRegistry.swift: ⌘K → type the row title → Return reveals the row
    (`settings.row.<id>`), which covers all 13 sections (the palette's settings search, AT-012).
Key tokens: ⌘ ⇧ ⌥ ⌃ + key, Tab, ⇧Tab, Return, Esc, Space, Up/Down/Left/Right, `type:<text>` (typed text),
`VO-Space` (VoiceOver activate, the Full Keyboard Access Space equivalent).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools/a11y/keyboard-paths.yml"
REGISTRY = ROOT / "Packages/UI/Sources/AntiChatUI/Settings/SettingsRegistry.swift"
DECK = json.loads((ROOT / "App/AntiChat/Localizable.xcstrings").read_text(encoding="utf-8"))["strings"]

# Q-015 r6: expected ids are the real ones the product carries (findField, findCount, thinkHarder, slashAtMenu,
# toolChip.<id>, dislikeMenu, msg.branch, assistantVersion; onboarding.step<n> is on the step container). Paths
# through ⌘K actions R-012 AC2 does not list (legal, what's new, report, library, projects, export, …) are spec
# gaps (PRD-AMENDMENTS A-Q015-r6-kb), kept as written until the amendment is decided.
FIXED = [
    # id, keys, expect
    ("app.newChat", ["⌘N"], "composer"),
    ("app.newIncognito", ["⇧⌘N"], "incognitoBadge"),
    ("app.newEvilChat", ["⇧⌘E"], "evil.frame"),
    ("app.palette", ["⌘K"], "palette.field"),
    ("app.paletteClose", ["⌘K", "Esc"], "composer"),
    ("app.settings", ["⌘,"], "settings.root"),
    ("app.shortcutList", ["⌘/"], "shortcutList"),
    ("app.toggleSidebar", ["⇧⌘S"], "chatColumn"),
    ("app.back", ["⌘N", "⌘["], "chatColumn"),
    ("app.forward", ["⌘N", "⌘[", "⌘]"], "chatColumn"),
    ("app.findInChat", ["⌘F"], "findField"),
    ("app.findNext", ["⌘F", "type:the", "Return"], "findCount"),
    ("app.findClose", ["⌘F", "Esc"], "composer"),
    ("app.newWindow", ["⌥⌘N"], "composer"),
    ("app.closeWindow", ["⌘W"], ""),
    ("app.help", ["⌘?"], "help.close"),
    ("app.legal", ["⌘K", "type:legal", "Return"], "legal.sheet"),
    ("app.whatsNew", ["⌘K", "type:what's new", "Return"], "whatsNew"),
    ("app.report", ["⌘K", "type:report", "Return"], "reportSheet"),
    ("report.attach", ["⌘K", "type:report", "Return"], "report.attach"),  # a plain button in the sheet's Tab order
    ("sidebar.focus", ["⌃⌘S"], "sidebar"),
    ("sidebar.nextChat", ["⌃⌘S", "Down"], "sidebar"),
    ("sidebar.openChat", ["⌃⌘S", "Down", "Return"], "chatColumn"),
    ("sidebar.library", ["⌘K", "type:library", "Return"], "library"),
    ("sidebar.projects", ["⌘K", "type:projects", "Return"], "projectsList"),
    ("sidebar.search", ["⌘K"], "palette.field"),
    ("chat.rename", ["⌥⌘R"], "toolbarTitle"),
    ("chat.pin", ["⌥⌘P"], "sidebar"),
    ("chat.archive", ["⇧⌘A"], "composer"),
    ("chat.delete", ["⇧⌘Delete"], "deleteConfirm"),
    ("chat.export", ["⌘K", "type:export", "Return"], "exportSheet"),
    ("chat.moveToProject", ["⌘K", "type:move to project", "Return"], "row.move"),
    ("chat.copyLastCode", ["⇧⌘;"], "composer"),
    ("composer.focus", ["⌘N"], "composer"),
    ("composer.send", ["type:Hello there.", "Return"], "assistantText"),
    ("composer.newline", ["type:a", "⇧Return", "type:b"], "composer"),
    ("composer.stop", ["type:Write a long story.", "Return", "Esc"], "sendButton"),
    ("composer.add", ["Tab", "VO-Space"], "composerAdd"),
    ("composer.attachFile", ["⌘K", "type:attach", "Return"], "composerAdd"),
    # ux/simplify: the mode picker sits in the toolbar and the new chat's Normal / Evil control above the composer;
    # the keyboard path of both is the pair of shortcuts (⇧⌘E moves a new chat to Evil, ⌘N back to Normal).
    ("composer.modeSwitch", ["⌘N", "⇧⌘E"], "modeSwitch"),
    ("composer.emptyModeEvil", ["⌘N", "⇧⌘E"], "emptyMode.evil"),
    ("composer.emptyModeNormal", ["⇧⌘E", "⌘N"], "emptyMode.normal"),
    ("composer.thinkHarder", ["Tab", "Tab", "VO-Space"], "thinkHarder"),
    ("composer.webSearchChip", ["type:/search", "Return"], "toolChip.web"),
    ("composer.slashMenu", ["type:/"], "slashAtMenu"),
    ("composer.slashSelect", ["type:/", "Down", "Return"], "toolChip.web"),
    ("composer.removeChip", ["type:/search", "Return", "Delete"], "composer"),
    ("composer.pasteCard", ["⌘V"], "composer"),
    ("composer.voice", ["⌃⇧V"], "voiceOverlay"),
    ("composer.dictation", ["⌃⇧D"], "dictationBar"),
    ("composer.incognitoToggle", ["⌘K", "type:incognito", "Return"], "incognitoBadge"),
    ("message.focus", ["type:Hello there.", "Return", "⇧Tab"], "assistantMessage"),
    ("message.copy", ["type:Hello there.", "Return", "⇧Tab", "⌘C"], "assistantMessage"),
    ("message.regenerate", ["type:Hello there.", "Return", "⇧Tab", "Tab", "VO-Space"], "assistantMessage"),
    ("message.readAloud", ["type:Hello there.", "Return", "⇧Tab", "Tab", "Tab", "VO-Space"], "assistantMessage"),
    ("message.like", ["type:Hello there.", "Return", "⇧Tab", "Tab", "Tab", "Tab", "VO-Space"], "assistantMessage"),
    ("message.dislike", ["type:Hello there.", "Return", "⇧Tab", "Tab", "Tab", "Tab", "Tab", "VO-Space"], "dislikeMenu"),
    ("message.more", ["type:Hello there.", "Return", "⇧Tab", "Tab", "Tab", "Tab", "Tab", "Tab", "VO-Space"], "msg.branch"),
    ("message.branch", ["type:Hello there.", "Return", "⌘K", "type:branch", "Return"], "chatColumn"),
    ("message.edit", ["type:Hello there.", "Return", "Up"], "inlineEditor"),
    ("message.editSend", ["type:Hello there.", "Return", "Up", "type: again", "Return"], "assistantText"),
    ("message.editCancel", ["type:Hello there.", "Return", "Up", "Esc"], "composer"),
    ("version.previous", ["type:Hello there.", "Return", "⇧Tab", "Tab", "VO-Space", "⌘["], "assistantVersion"),
    ("version.next", ["type:Hello there.", "Return", "⇧Tab", "Tab", "VO-Space", "⌘]"], "assistantVersion"),
    ("activity.expand", ["type:Search the web for news.", "Return", "⇧Tab", "VO-Space"], "activityDetail"),
    ("citation.open", ["type:Search the web for news.", "Return", "⇧Tab", "Tab", "VO-Space"], "citationHoverCard"),
    ("approval.allow", ["type:Run this code.", "Return", "Return"], "assistantText"),
    ("approval.deny", ["type:Run this code.", "Return", "Esc"], "assistantText"),
    ("artifact.openPanel", ["type:Make a chart.", "Return", "⇧Tab", "VO-Space"], "sidePanel"),
    ("artifact.closePanel", ["type:Make a chart.", "Return", "⇧Tab", "VO-Space", "Esc"], "composer"),
    ("artifact.download", ["type:Make a chart.", "Return", "⇧Tab", "VO-Space", "Tab", "VO-Space"], "sidePanel"),
    ("file.quickLook", ["type:Make a spreadsheet.", "Return", "⇧Tab", "Space"], "fileCard"),
    ("file.versionPrevious", ["type:Make a spreadsheet.", "Return", "⇧Tab", "Tab", "VO-Space"], "fileVersionSwitcher"),
    ("image.cancel", ["type:Make a picture.", "Return", "Esc"], "imageJobCard.status"),
    ("image.retry", ["type:Make a picture.", "Return", "⇧Tab", "VO-Space"], "imageJobCard.retry"),
    ("image.showPrompt", ["type:Make a picture.", "Return", "⇧Tab", "Tab", "VO-Space"], "imageJobCard.showPrompt"),
    ("voice.mute", ["⌃⇧V", "⌘M"], "voiceOverlay"),
    ("voice.end", ["⌃⇧V", "Esc"], "composer"),
    ("dictation.send", ["⌃⇧D", "Return"], "composer"),
    ("dictation.cancel", ["⌃⇧D", "Esc"], "composer"),
    ("palette.navigate", ["⌘K", "Down", "Down"], "palette.field"),
    ("palette.tabNext", ["⌘K", "⌃Tab"], "palette.field"),
    ("palette.openChat", ["⌘K", "type:chat", "Return"], "chatColumn"),
    ("palette.action", ["⌘K", "type:new incognito", "Return"], "incognitoBadge"),
    ("palette.liked", ["⌘K", "type:liked"], "palette.field"),
    ("shortcutList.close", ["⌘/", "Esc"], "composer"),
    ("sheet.cancel", ["⌘K", "type:export", "Return", "Esc"], "composer"),
    ("sheet.confirm", ["⌘K", "type:export", "Return", "Return"], "composer"),
    ("alert.default", ["⇧⌘Delete", "Return"], "composer"),
    ("alert.cancel", ["⇧⌘Delete", "Esc"], "composer"),
    ("evil.continueNew", ["⇧⌘E", "type:hi", "Return", "⌘K", "type:continue in normal", "Return"], "composer"),
    ("incognito.leave", ["⇧⌘N", "⇧⌘N"], "composer"),
    ("project.new", ["⌘K", "type:new project", "Return"], "project.new.name"),
    ("project.rename", ["⌘K", "type:projects", "Return", "Tab", "VO-Space"], "project.renameField"),
    ("project.delete", ["⌘K", "type:projects", "Return", "Tab", "Tab", "VO-Space"], "project.menu.delete"),
    ("project.addFile", ["⌘K", "type:projects", "Return", "Tab", "Tab", "Tab", "VO-Space"], "project.files.add"),
    ("library.openItem", ["⌘K", "type:library", "Return", "Tab", "Return"], "library"),
    ("onboarding.getStarted", ["Return"], "onboarding.step2"),
    ("onboarding.packToggle", ["Return", "Right", "Space"], "onboarding.step2"),
    ("onboarding.continue", ["Return", "Return"], "onboarding.step3"),
    ("onboarding.evilToggle", ["Return", "Return", "Space"], "onboarding.step3"),
    ("onboarding.adultCheck", ["Return", "Return", "Space", "Tab", "Space"], "onboarding.step3"),
    ("onboarding.back", ["Return", "⌘["], "onboarding.step1"),
    ("onboarding.finish", ["Return", "Return", "Return"], "onboarding.step4"),
    ("quickPanel.open", ["⌥Space"], "quickPanel"),
    ("quickPanel.send", ["⌥Space", "type:hi", "Return"], "quickPanel"),
    ("quickPanel.close", ["⌥Space", "Esc"], ""),
    ("menuBar.open", ["⌃F8", "Return"], ""),
    ("settings.nextSection", ["⌘,", "Down"], "settings.root"),
    ("settings.search", ["⌘,", "⌘F", "type:text size"], "settings.root"),
    # Settings is a view inside the main window (SettingsPresenter): Esc / "Back to chat" close it, ⌘W would close the window.
    ("settings.close", ["⌘,", "Esc"], "composer"),
    # Keyboard shortcuts is a sheet behind the General row's button (settings.control.shortcuts).
    ("settings.shortcutsSheet", ["⌘,", "⌘F", "type:Keyboard shortcuts", "Return", "Tab", "VO-Space"], "settings.shortcuts.sheet"),
    ("settings.shortcutRebind", ["⌘,", "⌘F", "type:Keyboard shortcuts", "Return", "Tab", "VO-Space", "Tab", "Space", "⌥⌘K"],
     "settings.shortcut.palette"),
    ("settings.connectionsDirectory", ["⌘K", "type:Connections", "Return"], "connections.search"),
    ("settings.skillsDirectory", ["⌘K", "type:Skills", "Return"], "skills.search"),
    ("uninstall.open", ["⌘K", "type:uninstall", "Return"], "uninstallSheet"),
    ("import.open", ["⌘K", "type:import", "Return"], "importSheet"),
    ("backup.restore", ["⌘K", "type:restore", "Return"], "restore.sheet"),
    ("storage.cleanup", ["⌘K", "type:clean up", "Return"], "cleanup.confirm"),
    ("help.uninstallPage", ["⌘?", "Tab", "Return"], "help.close"),
    ("systemReport.open", ["⌘K", "type:system report", "Return"], "systemReport"),
]


# Rows drawn by a view of their own carry that view's identifier, not `settings.row.<id>` (the pack rows, the two
# directory pages' headers, the model pickers' group): the path is the same, the proof is the real id.
ROW_EXPECT = {
    "pack.chat": "settings.pack.chat", "pack.voice": "settings.pack.voice", "pack.photo": "settings.pack.photo",
    "pack.video": "settings.pack.video", "pack.evil": "settings.pack.evil",
    "connections": "connections.intro", "addSkill": "skills.add", "modelOverrides": "settings.row.capabilities.models",
}


def settings_rows() -> list[tuple[str, str]]:
    out = []
    for m in re.finditer(r'\.init\("([A-Za-z0-9.]+)",\s*\.(\w+),\s*"([a-zA-Z0-9.]+)"', REGISTRY.read_text(encoding="utf-8")):
        rid, _section, key = m.groups()
        title = DECK.get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", key)
        out.append((rid, title))
    return out


def render() -> str:
    lines = ["# GENERATED by tools/a11y/gen-keyboard-paths.py (M9.T01 step 4, NFR-A3): every user function and its",
             "# keyboard-only path. KeyboardOnlyTests runs each entry with typeKey/typeText only and expects the",
             "# identifier. Do not edit: change the generator (fixed paths) or SettingsRegistry.swift (settings rows).", ""]
    entries = list(FIXED) + [(f"settings.{rid}", ["⌘K", f"type:{title}", "Return"], ROW_EXPECT.get(rid, f"settings.row.{rid}"))
                             for rid, title in settings_rows()]
    for eid, keys, expect in entries:
        lines += [f"- id: {eid}", f"  keys: [{', '.join(keys)}]", f"  expect: {expect}"]
    lines.append(f"# {len(entries)} entries")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    text = render()
    if a.check:
        ok = OUT.exists() and OUT.read_text(encoding="utf-8") == text
        print(f"keyboard-paths: {'ok' if ok else 'stale (run tools/a11y/gen-keyboard-paths.py)'}")
        return 0 if ok else 1
    OUT.write_text(text, encoding="utf-8")
    print(f"keyboard-paths: wrote {text.count('- id:')} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
