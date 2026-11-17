# Cómo desinstalar AntiChat

Hay dos formas. Las dos eliminan todo lo que AntiChat guarda en este Mac.

## 1. Usa Desinstalar AntiChat (recomendado)

Elige **AntiChat › Desinstalar AntiChat…** (o Ajustes › Privacidad y datos › Avanzado › Desinstalar AntiChat…). La ventana muestra lo que se eliminará y cuánto espacio libera. Haz clic en **Exportar antes mis datos** si quieres conservar tus chats; luego escribe UNINSTALL y haz clic en **Desinstalar**. AntiChat elimina sus modelos, chats, imágenes, archivos, cachés, registros y ajustes, desactiva Abrir al iniciar sesión, borra sus atajos de teclado, se mueve a la Papelera y se cierra.

## 2. Elimínalo a mano

1. Cierra AntiChat.
2. Arrastra **AntiChat** desde la carpeta Aplicaciones a la Papelera.
3. En Finder, elige **Ir › Ir a la carpeta…** y elimina cada uno de estos elementos, si existe:

- `~/Library/Application Support/AntiChat` (chats, imágenes, archivos, copias de seguridad, modelos)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (cachés de descargas y actualizaciones)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (temporal; macOS también lo borra al reiniciar)

Si moviste la carpeta de modelos a otro disco (Ajustes › Privacidad y datos › Avanzado › Carpeta de modelos › Mover…), elimina también esa carpeta. Ajustes › Privacidad y datos › Avanzado muestra dónde está, con Mostrar en Finder.

Los elementos del llavero llamados app.antichat.* se pueden eliminar en Acceso a Llaveros.

## Time Machine

La carpeta de modelos nunca se incluye en las copias de seguridad de Time Machine. Los chats de copias de Time Machine antiguas son tuyos y te toca a ti eliminarlos; desinstalar AntiChat no cambia las copias existentes.
