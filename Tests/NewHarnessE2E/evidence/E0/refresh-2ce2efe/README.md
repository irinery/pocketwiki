# Reexecução E0 isolada — PocketWiki 2ce2efe

Os três shards foram executados contra o mesmo código PocketWiki `2ce2efee4b3ef98d803f52d6b887020a074cce52`, PocketKernel `03f8f30eb781b4d16a9dca76f7548f9781bbef02` e MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`.

## Resultados

- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface service --report-dir /tmp/nh-test-e0-isolated/service` — exit 0. `CONTRACT-00/service` passou com contratos, aceite/bootstrap, Chromium, interoperabilidade, rig, `script/ci.sh` e matriz.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface web --report-dir /tmp/nh-test-e0-isolated/web` — exit 0. `LEGACY-00/web` passou com processos reais, store preservado através do restart de PocketWiki e restauração da conversa.
- `node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface macos --report-dir /tmp/nh-test-e0-isolated/macos` — exit 2. XCTest não executou porque o host local só tem Command Line Tools; o launcher exige Xcode completo.
- `node Tests/NewHarnessE2E/gate-aggregator.mjs --stage E0 --reports /tmp/nh-test-e0-isolated/service/e0-service.json /tmp/nh-test-e0-isolated/web/e0-web.json /tmp/nh-test-e0-isolated/macos/e0-macos.json` — exit 1, `gate rejected: shard exit_code is not zero`. Nenhum `gate_passed=true` foi emitido.

O shard service agora clona o commit PocketWiki para um diretório temporário e executa a regressão nesse clone, usando snapshots dos dois helpers. O checkout do usuário não recebe `npm ci` nem `script/ci.sh`. Durante esta execução, as 155 cópias untracked `* 2.*` do bundle Excalidraw permaneceram no diretório original.

Os relatórios, JUnit, logs, captura e trace Playwright redigido estão nas pastas dos shards. A verificação por canários não encontrou credenciais nos logs/trace.

## Hashes

- Schema `harness-v1.schema.json`: `306915400385fa9bd7c22096fb18228d4d2c02e0f272376f8c2c5ebd7bebae70`
- Fixtures agregadas: `697f4057f4f5aeef584ed42a88a895261845cb6834eb994fb2c8878440c74b0c`
- Corpus `corpus-v1.json`: `9aef5fbe89e3d129ebcf54a8dab048780ba1bb65519c0e8d1eb607846b107ef9`
- Matriz: `d0a1404c0dfae0bd330a21a0e95941dc76614aa6837dda01713a9635c368c95f`
- Seed: `20261102`; `auth_mode`: `host_local`.

O commit que adiciona esta evidência é posterior ao SHA testado acima.
