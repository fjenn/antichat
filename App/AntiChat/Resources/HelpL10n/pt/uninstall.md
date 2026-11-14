# Como desinstalar o AntiChat

Há duas maneiras. As duas removem tudo o que o AntiChat guarda neste Mac.

## 1. Use Desinstalar o AntiChat (recomendado)

Escolha **AntiChat › Desinstalar o AntiChat…** (ou Ajustes › Armazenamento › Desinstalar o AntiChat…). A janela lista o que será removido e quanto espaço isso libera. Clique em **Exportar meus dados antes** se quiser manter suas conversas, depois digite UNINSTALL e clique em **Desinstalar**. O AntiChat remove seus modelos, conversas, imagens, arquivos, caches, registros e ajustes, desativa Abrir ao iniciar sessão, limpa seus atalhos de teclado, se move para a Lixeira e é encerrado.

## 2. Remova manualmente

1. Encerre o AntiChat.
2. Arraste o **AntiChat** de Aplicativos para a Lixeira.
3. No Finder, escolha **Ir › Ir para a Pasta…** e apague cada um destes itens, se existir:

- `~/Library/Application Support/AntiChat` (conversas, imagens, arquivos, backups, modelos)
- `~/Library/Caches/AntiChat`
- `~/Library/Logs/AntiChat`
- `~/Library/Preferences/app.antichat.AntiChat.plist`
- `~/Library/Saved Application State/app.antichat.AntiChat.savedState`
- `~/Library/HTTPStorages/app.antichat.AntiChat*`
- `~/Library/WebKit/app.antichat.AntiChat`
- `~/Library/Caches/app.antichat.AntiChat*` (caches de downloads e atualizações)
- `~/Library/Containers/app.antichat.AntiChat.FileTools*`
- `~/Library/Logs/DiagnosticReports/AntiChat*.ips`
- `$TMPDIR/AntiChat-incognito-*` (temporário; o macOS também o limpa ao reiniciar)

Se você moveu a pasta dos modelos para outro disco (Ajustes › Armazenamento › Pasta dos modelos › Mover…), apague essa pasta também. Ajustes › Armazenamento mostra onde ela está, com Mostrar no Finder.

Os itens das Chaves chamados app.antichat.* podem ser apagados no Acesso às Chaves.

## Time Machine

A pasta dos modelos nunca é incluída nos backups do Time Machine. Cabe a você apagar as conversas em backups antigos do Time Machine; desinstalar o AntiChat não altera os backups existentes.
