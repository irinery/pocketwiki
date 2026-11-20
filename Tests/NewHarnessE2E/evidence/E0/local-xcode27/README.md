# LEGACY-00 macOS — execução local

Executado em 2026-11-14 em macOS 26.6.2 arm64 com Xcode 27.2 (27B52), Node 26.13.0 e Go 1.27.3. Base PocketWiki `0f470ebacd4758d0517e5565aaf900af9f1a2486`, mais a correção de UI deste commit; PocketKernel `03f8f30eb781b4d16a9dca76f7548f9781bbef02` e MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`.

Com checkouts limpos nos SHAs acima, o comando foi:

```sh
POCKETKERNEL_NH00_ROOT="$KERNEL_CHECKOUT" \
MIDDLEWAREAUTH_NHTEST_ROOT="$MIDDLEWARE_CHECKOUT" \
node Tests/NewHarnessE2E/MacOSHost/run.mjs --result-bundle-path /tmp/legacy00-macos.xcresult
```

Resultado: exit 0; `Legacy00UITests.testLegacy00UsesRealAppBridgeAndRestoresAfterRestart` passou, 1 teste, zero falhas e zero skips. O launcher confirmou requisição autenticada à fixture, modelo `nh-test-model` e marcador `nh-test-marker-2026` no contexto da wiki. A asserção do teste também confirmou persistência e restauração após reiniciar o app. O resumo abaixo omite identificadores do dispositivo, caminhos locais e horários.

```json
{"result":"Passed","passedTests":1,"failedTests":0,"skippedTests":0,"totalTestCount":1,"provider":{"authorized":true,"prompt_contains_wiki_marker":true,"model":"nh-test-model"}}
```

Esta execução cobre somente `LEGACY-00/macos`; a aprovação agregada do E0 continua documentada pelo run 41621854497, em Xcode 16.4.
