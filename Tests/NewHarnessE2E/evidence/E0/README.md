# Evidências E0 — NH-TEST

Execução feita sobre o código PocketWiki `4e60dc4de9df81b272524cad1fbb440579480330`, com base de handoff NH-00 `5d516e59c6fcdf41a551f8725d1ca19d770d41c1`, PocketKernel `03f8f30eb781b4d16a9dca76f7548f9781bbef02` e MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`.

## Comandos e resultados

- `npm run test:new-harness-rig` — passou, 6/6 testes.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface service --report-dir /tmp/nh-test-e0-final-v2/service` — exit 0; inclui as regressões de `script/ci.sh` e `script/build_nh00_matrix.sh`.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface web --report-dir /tmp/nh-test-e0-final-v2/web` — exit 0; PocketWiki, PocketKernel e MiddlewareAuth reais, stores temporários e provider fixture local.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface macos --report-dir /tmp/nh-test-e0-final-v2/macos` — exit 2; Xcode/XCTest completo indisponível neste Mac.
- `node Tests/NewHarnessE2E/gate-aggregator.mjs --stage E0 --reports /tmp/nh-test-e0-final-v2/service/e0-service.json /tmp/nh-test-e0-final-v2/web/e0-web.json /tmp/nh-test-e0-final-v2/macos/e0-macos.json` — rejeitou com `shard exit_code is not zero`; nenhum `gate_passed=true` foi produzido.

Os relatórios, JUnit, logs, screenshot, trace Playwright e evidência sanitizada estão nas pastas `service/`, `web/` e `macos/`. O trace e logs foram conferidos contra os canários de provider, middleware e memória; nenhum valor ficou exposto.

## Hashes

- Schema `harness-v1.schema.json`: `306915400385fa9bd7c22096fb18228d4d2c02e0f272376f8c2c5ebd7bebae70`
- Fixture agregada do relatório: `697f4057f4f5aeef584ed42a88a895261845cb6834eb994fb2c8878440c74b0c`
- Corpus `corpus-v1.json`: `9aef5fbe89e3d129ebcf54a8dab048780ba1bb65519c0e8d1eb607846b107ef9`
- Matriz E0: `d0a1404c0dfae0bd330a21a0e95941dc76614aa6837dda01713a9635c368c95f`

Os relatórios apontam para o SHA do código executado. A alteração final deste commit adiciona apenas estas evidências e este README.

Reexecução após revisar o restart do servidor web e preparar a lane macOS/CI: [refresh-9ffd0b6](refresh-9ffd0b6/README.md). Ela registra o SHA corrente testado, o restart real de processo web e a rejeição do agregador enquanto o shard XCTest não puder rodar.

Reexecução final com regressão service em clone temporário, sem tocar nos untracked da worktree: [refresh-2ce2efe](refresh-2ce2efe/README.md). Service e web passaram no mesmo SHA; XCTest permanece pendente do runner macOS com Xcode.
