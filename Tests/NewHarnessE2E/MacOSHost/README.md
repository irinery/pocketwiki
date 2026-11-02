# Host macOS do LEGACY-00

O app de teste é uma cópia macOS do app legado compilada dos fontes de `Sources/PocketWikiMac`, com bundle ID de teste `com.pocketwiki.NHTestHost`. O XCTest usa `XCUIApplication` para abrir a aplicação real, escolhe uma pasta fixture pelo painel real do macOS, configura o provider LM Studio de fixture pela UI, envia uma pergunta, confirma a resposta e reinicia o processo para verificar bookmark e sessão.

O launcher compila os executáveis reais PocketKernel e MiddlewareAuth dos worktrees pinados em diretório temporário, inicia um endpoint fixture OpenAI compatível só na fronteira LM Studio autorizada e executa `xcodebuild test`. O fixture só retorna resposta 200 quando recebeu uma chamada autenticada pelo MiddlewareAuth, no modelo esperado, e o prompt compilado pelo Kernel contém `nh-test-marker-2026`; a fixture não substitui Kernel, política, contexto/MCP, bridge nem MiddlewareAuth. Os stores da wiki, memória, conversas, credenciais e UserDefaults ficam em diretórios temporários por execução.

O runner grava `.xcresult` e um `.log` irmão do bundle de resultados. O log registra as chamadas vistas no provider fixture sem salvar o conteúdo bruto do prompt ou credenciais.

Pré-requisito: Xcode completo com SDK macOS e XCTest. Não use apenas Command Line Tools. Execução manual após integrar o projeto Xcode:

```sh
node Tests/NewHarnessE2E/MacOSHost/run.mjs --result-bundle-path /tmp/legacy00-macos.xcresult
```

Para usar uma instalação sem trocar a seleção global do `xcode-select`, defina `POCKETWIKI_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

A lane só deve reportar `passed` se `xcodebuild test` terminar com código zero e o caso `Legacy00UITests/testLegacy00UsesRealAppBridgeAndRestoresAfterRestart` passar, e o log confirmar ao menos uma chamada fixture autenticada contendo o marcador recuperado da wiki. Se Xcode não estiver disponível, reportar indisponível/falha de configuração; não sintetizar resultado aprovado.
