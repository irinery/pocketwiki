# E0 — execução agregada aprovada

- Workflow: [New Harness E0 run 41589383623](https://github.com/irinery/pocketwiki/actions/runs/41589383623)
- Branch: `codex/nh-e0-nhtest`
- SHA testado: `41dcae61aa9620eca508ad1ff0bb3e2fe2739216`
- Base NH-00: `5d516e59c6fcdf41a551f8725d1ca19d770d41c1`
- PocketKernel: `03f8f30eb781b4d16a9dca76f7548f9781bbef02`
- MiddlewareAuth: `04f44f62126c785f7b28718d2eff837c28cb65df`
- Ambiente: `macos-15`, Xcode 16.4, Node 22.14.0, Go 1.26.0.
- Resultado: `gate_passed=true`; `CONTRACT-00/service`, `LEGACY-00/web` e `LEGACY-00/macos` passaram no mesmo SHA. JUnit: 3 testes, 0 falhas; macOS 15.8.2: 1 teste aprovado.

## Comandos e resultados

O workflow executou a matriz completa e o agregador nesta ordem:

```sh
node Tests/NewHarnessE2E/runner.mjs --stage E0 --surface all --report-dir "$RUNNER_TEMP/nh-test-e0"
node Tests/NewHarnessE2E/gate-aggregator.mjs --stage E0 --reports "$RUNNER_TEMP/nh-test-e0/e0-all.json" > "$RUNNER_TEMP/nh-test-e0/gate.json"
```

Shards aprovados: `LEGACY-00/web`, `LEGACY-00/macos`, `CONTRACT-00/service`. Regressão aplicável também aprovada:

```sh
sh script/ci.sh
sh script/build_nh00_matrix.sh
```

Os validadores do contrato passaram: `npm run test:harness-contracts`, `sh scripts/test-nh00-acceptance.sh`, `npm run test:nh00-bootstrap`, `npm run test:nh00-chromium`, `sh script/validate_pocket_interop_contract.sh` e `npm run test:new-harness-rig`.

## Identidade dos inputs

- Schema `src/harness/contracts/harness-v1.schema.json`: `306915400385fa9bd7c22096fb18228d4d2c02e0f272376f8c2c5ebd7bebae70`
- Fixtures compostas (corpus, registry, regressões NH-00 e manifest): `697f4057f4f5aeef584ed42a88a895261845cb6834eb994fb2c8878440c74b0c`
- Matriz `docs/rfcs/new-harness/matriz-verificacao.json`: `d0a1404c0dfae0bd330a21a0e95941dc76614aa6837dda01713a9635c368c95f`
- Seed: `20261102`; `auth_mode=host_local`.

## Artefatos e redaction

`e0-all.json`, `gate.json`, JUnit, resumo XCTest, evidência do provider web, screenshot, traces e logs redigidos estão junto deste arquivo. O `.xcresult` bruto não foi incluído; o launcher exportou somente o resumo XCTest para não publicar snapshots brutos. Uma varredura local deste pacote e do trace web confirmou que as credenciais fixture fixas não aparecem no conteúdo.

Artifact do Actions: `nh-test-e0-41589383623-1`, digest SHA-256 `235b6ffcd1d0fd9407c332e55ec4d62fbaece3202b5efa895f1bcb28f76dd50e` (retenção até 2026-11-17).
