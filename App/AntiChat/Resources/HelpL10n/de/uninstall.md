# So deinstallierst du AntiChat

Es gibt zwei Wege. Beide entfernen alles, was AntiChat auf diesem Mac speichert.

## 1. AntiChat deinstallieren verwenden (empfohlen)

Wähl **AntiChat › AntiChat deinstallieren …** (oder Einstellungen › Datenschutz & Daten › Erweitert › AntiChat deinstallieren …). Das Fenster zeigt, was entfernt wird und wie viel Platz das freigibt. Klick auf **Erst meine Daten exportieren**, wenn du deine Chats behalten willst, gib dann UNINSTALL ein und klick auf **Deinstallieren**. AntiChat entfernt seine Modelle, Chats, Bilder, Dateien, Caches, Protokolle und Einstellungen, schaltet „Beim Anmelden öffnen“ aus, löscht seine Tastenkürzel, legt sich selbst in den Papierkorb und wird beendet.

## 2. Von Hand entfernen

1. Beende AntiChat.
2. Zieh **AntiChat** aus dem Ordner „Programme“ in den Papierkorb.
3. Wähl im Finder **Gehe zu › Gehe zum Ordner …** und lösch jeden dieser Einträge, falls vorhanden:

- `~/Library/Application Support/AntiChat` (Chats, Bilder, Dateien, Backups, Modelle)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (Download- und Update-Caches)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (temporär; macOS löscht es auch beim Neustart)

Wenn du den Modellordner auf ein anderes Laufwerk verschoben hast (Einstellungen › Datenschutz & Daten › Erweitert › Modellordner › Verschieben …), lösch auch diesen Ordner. Einstellungen › Datenschutz & Daten › Erweitert zeigt, wo er liegt, mit „Im Finder anzeigen“.

Schlüsselbundeinträge mit dem Namen app.antichat.* kannst du in der Schlüsselbundverwaltung löschen.

## Time Machine

Der Modellordner wird nie in Time-Machine-Backups aufgenommen. Chats in älteren Time-Machine-Backups musst du selbst löschen; das Deinstallieren von AntiChat ändert bestehende Backups nicht.
