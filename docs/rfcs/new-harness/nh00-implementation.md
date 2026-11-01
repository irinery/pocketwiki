# NH-00 — registro de implementação

## Bases e refs

- PocketWiki integrado/documental: `5311a8aae2876c572f25b79540f38ee0acac7121`.
- PocketWiki implementação: branch `codex/nh-e0-nh00`; use o HEAD desta branch como ref da lane.
- PocketKernel base: `02fe052516a3bd53f4fab4d94cd566540bce276c`.
- PocketKernel implementação: branch `codex/nh00-locks`; commit `ff32bbc9f386ef4f4be55da281c481d79a4a5299`.
- MiddlewareAuth não alterado: `04f44f62126c785f7b28718d2eff837c28cb65df` (`main`).

PocketWiki e PocketKernel são históricos separados. Não copiar commits entre repositórios.

## Entrega

- Schemas fechados dos envelopes Harness v1, dos 46 tipos de entidade, dos 15 snapshots modulares e dos inputs de operação extraídos das RFCs.
- Corpus JSON compartilhado pelos validadores JS/Swift; 50 operações no registry com owner, classe, input schema e slot NH00-OP.
- Todos os módulos e operações futuras continuam desabilitados em capabilities até existir handler real.
- Bootstrap local scoped em memória: bearer aleatório de 32 bytes, entregue pelo canal de processo injetado; só o hash é persistido. Identidade, audience, scopes, thread opcional e revogação são verificadas.
- Playwright fixado em 1.64.1 e Chromium Playwright revision 1248 (Chrome for Testing 156.0.8078.4).
- Kernel fixa Go 1.26.0, modernc.org/sqlite 1.61.1 e creack/pty 1.1.24. `script/build_nh00_matrix.sh` produz binários Linux arm64/amd64 com CGO desligado.
- APIs `/v1/kernel`, `/api/memory/*` e MCP Evidence não foram alteradas.

## Contratos pendentes

A issue #21 contém o bloqueio sobre a duplicação de `command_id` e `expected_revision` entre `HarnessCommand` e a entrada de `runtime.dispatch`, e sobre a ausência de TTL para o bearer local. `runtime.dispatch` fica fora dos comandos válidos até resolução. `SessionGrant` está definido e seu schema foi gerado.

O gate E0 não está aprovado: o rig NH-TEST (#22) e a revisão integrada do GATE-E0 (#38) continuam necessários antes de E1. Esta lane não implementa domínios das RFCs futuras.

## Integração

1. Em PocketWiki, crie uma branch de integração a partir de `5311a8aae2876c572f25b79540f38ee0acac7121` e aplique, em ordem, os commits da branch `codex/nh-e0-nh00` após a base.
2. Em PocketKernel, crie a branch de integração a partir de `02fe052516a3bd53f4fab4d94cd566540bce276c` e aplique `ff32bbc9f386ef4f4be55da281c481d79a4a5299`.
3. Registre os dois SHAs de integração e o SHA MiddlewareAuth acima na issue #21; mantenha MiddlewareAuth sem alterações nesta etapa.
4. Rode `npm run generate:harness-contracts`, `npm run test:harness-contracts`, `npm test`, `swift build -c debug`, `CGO_ENABLED=0 go test ./...` e `sh script/build_nh00_matrix.sh`. Só depois do rig NH-TEST e da revisão do gate E0 libere E1.
