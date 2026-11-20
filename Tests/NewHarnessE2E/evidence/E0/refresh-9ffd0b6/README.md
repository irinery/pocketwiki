# Reexecução E0 — PocketWiki 9ffd0b6

Os três shards foram executados contra o mesmo código PocketWiki `9ffd0b62709e77e0906ddfd8169237a9411057f4`, o pin PocketKernel `03f8f30eb781b4d16a9dca76f7548f9781bbef02` e o pin MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`.

## Resultados

- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface service --report-dir /tmp/nh-test-e0-current/service` — exit 0. `CONTRACT-00/service` passou; inclui contratos JS/Swift, aceite/bootstrap, Chromium, interoperabilidade, rig, `script/ci.sh` e `script/build_nh00_matrix.sh`.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface web --report-dir /tmp/nh-test-e0-current/web` — exit 0. `LEGACY-00/web` passou com PocketWiki, Kernel e MiddlewareAuth reais. O teste encerrou e reiniciou o processo PocketWiki na mesma porta, releu o mesmo store e restaurou a conversa no browser persistente.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface macos --report-dir /tmp/nh-test-e0-current/macos` — exit 2. O host não tem Xcode.app/XCTest; o shard registrou falha de configuração, sem skip ou aprovação.
- `node Tests/NewHarnessE2E/gate-aggregator.mjs --stage E0 --reports /tmp/nh-test-e0-current/service/e0-service.json /tmp/nh-test-e0-current/web/e0-web.json /tmp/nh-test-e0-current/macos/e0-macos.json` — exit 1, `gate rejected: shard exit_code is not zero`. Não foi emitido `gate_passed=true`.

Os JSONs de shard, JUnit, logs, screenshot web, trace Playwright redigido e evidência do restart estão nas pastas `service/`, `web/` e `macos/`. O teste do trace contra os canários de provider, middleware e memória não encontrou valores expostos.

## Identidade e hashes

- Schema `harness-v1.schema.json`: `306915400385fa9bd7c22096fb18228d4d2c02e0f272376f8c2c5ebd7bebae70`
- Fixtures agregadas usadas pelo relatório: `697f4057f4f5aeef584ed42a88a895261845cb6834eb994fb2c8878440c74b0c`
- Corpus `corpus-v1.json`: `9aef5fbe89e3d129ebcf54a8dab048780ba1bb65519c0e8d1eb607846b107ef9`
- Matriz E0: `d0a1404c0dfae0bd330a21a0e95941dc76614aa6837dda01713a9635c368c95f`
- Seed: `20261102`; `auth_mode`: `host_local`.

O commit que contém apenas esta atualização de evidências vem depois do SHA efetivamente testado acima; os relatórios não alegam testar esse commit de evidências.
