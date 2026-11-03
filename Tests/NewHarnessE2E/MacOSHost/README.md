# Host macOS do LEGACY-00

O app de teste é uma cópia macOS do app legado compilada dos fontes de `Sources/PocketWikiMac`, com bundle ID de teste `com.pocketwiki.NHTestHost`. O XCTest usa `XCUIApplication` para abrir a aplicação real, escolhe uma pasta fixture pelo painel real do macOS, configura o provider LM Studio de fixture pela UI, envia uma pergunta, confirma a resposta e reinicia o processo para verificar bookmark e sessão.

O launcher compila os executáveis reais PocketKernel e MiddlewareAuth dos checkouts pinados em diretório temporário, inicia um endpoint fixture OpenAI compatível só na fronteira LM Studio autorizada e executa `xcodebuild test`. O fixture só retorna resposta 200 quando recebeu uma chamada autenticada pelo MiddlewareAuth, no modelo esperado, e o prompt compilado pelo Kernel contém `nh-test-marker-2026`; a fixture não substitui Kernel, política, contexto/MCP, bridge nem MiddlewareAuth. Os stores da wiki, memória, conversas, credenciais e UserDefaults ficam em diretórios temporários por execução.

O launcher extrai do `.xcresult` apenas o resumo JSON do XCTest, redige os canários de credencial e remove o bundle bruto, que pode conter snapshots de UI. O runner externo registra o log redigido, o resumo JSON e o JUnit. A evidência do provider guarda contagem/modelo e flags do marcador, sem corpo do prompt nem credenciais.

Pré-requisito: Xcode completo com SDK macOS e XCTest, Node.js 22.14.0 e Go 1.26.0. Não use apenas Command Line Tools. O workflow [`new-harness-e0.yml`](../../../.github/workflows/new-harness-e0.yml) fixa Xcode 16.4, os SHAs de PocketKernel/MiddlewareAuth registrados em `nhtest-base-shas.md` e os pins Swift do projeto. Ele roda a matriz inteira E0 no mesmo checkout PocketWiki, agrega os relatórios e publica os artefatos redigidos.

Execução manual exige checkouts locais nestes caminhos (ou as variáveis equivalentes abaixo):

```sh
git clone https://github.com/irinery/pocketkernel.git ../pocketkernel-nh00
git -C ../pocketkernel-nh00 checkout 03f8f30eb781b4d16a9dca76f7548f9781bbef02
git clone https://github.com/irinery/middlewareAuth.git ../middlewareAuth
git -C ../middlewareAuth checkout 04f44f62126c785f7b28718d2eff837c28cb65df
node Tests/NewHarnessE2E/MacOSHost/run.mjs --result-bundle-path /tmp/legacy00-macos.xcresult
```

Para usar uma instalação sem trocar a seleção global do `xcode-select`, defina `POCKETWIKI_XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

A lane só deve reportar `passed` se `xcodebuild test` terminar com código zero e o caso `Legacy00UITests/testLegacy00UsesRealAppBridgeAndRestoresAfterRestart` passar, e o log confirmar ao menos uma chamada fixture autenticada contendo o marcador recuperado da wiki. Se Xcode não estiver disponível, reportar indisponível/falha de configuração; não sintetizar resultado aprovado.
