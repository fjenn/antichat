# Comment désinstaller AntiChat

Il y a deux façons de faire. Les deux suppriment tout ce qu’AntiChat conserve sur ce Mac.

## 1. Utiliser Désinstaller AntiChat (recommandé)

Choisissez **AntiChat › Désinstaller AntiChat…** (ou Réglages › Stockage › Désinstaller AntiChat…). La fenêtre indique ce qui sera supprimé et l’espace libéré. Cliquez sur **Exporter d’abord mes données** si vous voulez garder vos discussions, puis tapez UNINSTALL et cliquez sur **Désinstaller**. AntiChat supprime ses modèles, discussions, images, fichiers, caches, journaux et réglages, désactive Ouvrir à la connexion, efface ses raccourcis clavier, se place dans la Corbeille et se ferme.

## 2. Supprimer à la main

1. Quittez AntiChat.
2. Faites glisser **AntiChat** depuis le dossier Applications vers la Corbeille.
3. Dans le Finder, choisissez **Aller › Aller au dossier…** et supprimez chacun des éléments suivants, s’il existe :

- `~/Library/Application Support/AntiChat` (discussions, images, fichiers, sauvegardes, modèles)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (caches de téléchargement et de mise à jour)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (temporaire ; macOS le vide aussi au redémarrage)

Si vous avez déplacé le dossier des modèles vers un autre disque (Réglages › Stockage › Dossier des modèles › Déplacer…), supprimez aussi ce dossier. Réglages › Stockage indique où il se trouve, avec Afficher dans le Finder.

Les éléments du trousseau nommés app.antichat.* peuvent être supprimés dans Trousseaux d’accès.

## Time Machine

Le dossier des modèles n’est jamais inclus dans les sauvegardes Time Machine. C’est à vous de supprimer les discussions présentes dans d’anciennes sauvegardes Time Machine ; désinstaller AntiChat ne modifie pas les sauvegardes existantes.
