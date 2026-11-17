# How to uninstall AntiChat

There are two ways. Both remove everything AntiChat keeps on this Mac.

## 1. Use Uninstall AntiChat (recommended)

Choose **AntiChat › Uninstall AntiChat…** (or Settings › Privacy & Data › Advanced › Uninstall AntiChat…). The sheet lists what will be removed and how much space it frees. Click **Export my data first** if you want to keep your chats, then type UNINSTALL and click **Uninstall**. AntiChat removes its models, chats, pictures, files, caches, logs and settings, turns off Launch at login, clears its keyboard shortcuts, moves itself to the Trash and quits.

## 2. Remove it by hand

1. Quit AntiChat.
2. Drag **AntiChat** from Applications to the Trash.
3. In Finder, choose **Go › Go to Folder…** and delete each of these, if it exists:

- `~/Library/Application Support/AntiChat` (chats, pictures, files, backups, models)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (download and update caches)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (temporary; macOS also clears it on restart)

If you moved the Models folder to another drive (Settings › Privacy & Data › Advanced › Models folder › Move…), delete that folder too. Settings › Privacy & Data › Advanced shows where it is, with Show in Finder.

Keychain items named app.antichat.* can be deleted in Keychain Access.

## Time Machine

The Models folder is never included in Time Machine backups. Chats in older Time Machine backups remain the user's to delete; uninstalling AntiChat does not change existing backups.
