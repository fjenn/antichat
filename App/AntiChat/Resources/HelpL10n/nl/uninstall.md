# Zo verwijder je AntiChat

Er zijn twee manieren. Beide verwijderen alles wat AntiChat op deze Mac bewaart.

## 1. Gebruik Verwijder AntiChat (aanbevolen)

Kies **AntiChat › Verwijder AntiChat…** (of Instellingen › Opslag › Verwijder AntiChat…). Het venster toont wat er wordt verwijderd en hoeveel ruimte dat vrijmaakt. Klik op **Exporteer eerst mijn gegevens** als je je chats wilt bewaren, typ dan UNINSTALL en klik op **Verwijder**. AntiChat verwijdert zijn modellen, chats, afbeeldingen, bestanden, caches, logbestanden en instellingen, zet Open bij inloggen uit, wist zijn toetscombinaties, verplaatst zichzelf naar de prullenmand en stopt.

## 2. Verwijder het met de hand

1. Stop AntiChat.
2. Sleep **AntiChat** van de map Programma's naar de prullenmand.
3. Kies in de Finder **Ga › Ga naar map…** en verwijder elk van deze onderdelen, als het bestaat:

- `~/Library/Application Support/AntiChat` (chats, afbeeldingen, bestanden, reservekopieën, modellen)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (caches voor downloads en updates)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (tijdelijk; macOS wist het ook bij herstarten)

Als je de modellenmap naar een andere schijf hebt verplaatst (Instellingen › Opslag › Modellenmap › Verplaats…), verwijder die map dan ook. Instellingen › Opslag toont waar hij staat, met Toon in Finder.

Sleutelhangeronderdelen met de naam app.antichat.* kun je verwijderen in Sleutelhangertoegang.

## Time Machine

De modellenmap wordt nooit opgenomen in Time Machine-reservekopieën. Chats in oudere Time Machine-reservekopieën moet je zelf verwijderen; AntiChat verwijderen verandert bestaande reservekopieën niet.
