# NH-00 — registro de implementação

## Estado

- Entrega parcial para revisão NH-00; não iniciar NH-TEST até esta revisão ser aceita.
- PocketWiki base documental: `5311a8aae2876c572f25b79540f38ee0acac7121` (`codex/new-harness-rfcs`).
- PocketWiki base integrada com `main` (ancestral comum da base documental): `7703ac708120d93f54c7d29c5ad34dde9591a1bf`.
- PR documental #45 ainda aberto; o SHA `5311a8a` não foi mesclado em `main`.
- PocketWiki implementação: branch `codex/nh-e0-nh00`; o HEAD da lane é separado dessas duas bases.
- PocketKernel base: `02fe052516a3bd53f4fab4d94cd566540bce276c`.
- PocketKernel implementação: branch `codex/nh00-locks`; commit `ff32bbc9f386ef4f4be55da281c481d79a4a5299`.
- MiddlewareAuth não alterado: `04f44f62126c785f7b28718d2eff837c28cb65df` (`main`).

PocketWiki e PocketKernel são históricos separados. Não copiar commits entre repositórios.

## Entrega nesta revisão

- Schemas fechados dos envelopes Harness v1, dos 46 tipos de entidade, dos 15 snapshots modulares, das unions discriminadas `PermissionAction`/`ForgePreview` e dos inputs de operação.
- Validadores recursivos JS/Swift consomem o mesmo schema e os mesmos slots. O corpus compartilhado tem 280 casos: contraexemplos aninhados, variantes cruzadas, optional/null e 232 slots de operação (casos válidos, schema fechado, limites de schema e condições cruzadas verificáveis em E0).
- Registry das 50 operações mantém owner, classe, input schema, texto normativo `validation` por campo e slot NH00-OP. Pré-condições que exigem estado/autorização estão declaradas no registry, sem fingir handlers dos domínios futuros.
- Todos os módulos e operações futuras continuam desabilitados em capabilities até existir handler real.
- Bootstrap local scoped: bearer aleatório de 32 bytes, entregue pelo canal de processo injetado; só o hash é persistido. TTL de 900000 ms, metadados incluem `expires_at_ms`, autenticação expira no limite inclusivo e reiniciar o host invalida credenciais.
- Playwright fixado em 1.64.1 e Chromium Playwright revision 1248 (Chrome for Testing 156.0.8078.4).
- Kernel fixa Go 1.26.0, modernc.org/sqlite 1.61.1 e creack/pty 1.1.24. `script/build_nh00_matrix.sh` produz binários Linux arm64/amd64 com CGO desligado.
- APIs `/v1/kernel`, `/api/memory/*` e MCP Evidence não foram alteradas.

## Esclarecimentos fechados nesta revisão; aguardam aceite

- `runtime.dispatch`: os campos repetidos `command_id` e `expected_revision` têm de ser iguais aos do envelope; divergência retorna `ERR_INVALID` antes de efeito. Mantém-se o wire da RFC, e a operação deixa de estar marcada como bloqueada.
- Credencial local: TTL definido em 900000 ms; `expires_at_ms` faz parte dos metadados privados de bootstrap; expiração retorna `ERR_EXPIRED`; credenciais ativas não sobrevivem ao reinício do host.
- Opcionalidade é independente de nulabilidade: ausência depende de `obrigatório: false`; JSON `null` só é aceito no tipo com sufixo `?`.
- `navigation.update.read_through_seq` fica obrigatório em todas as ações conforme a lista de campos, mas só é consumido por `mark_read`; `before_thread_id` só vale para `reorder`.
- `SessionGrant` já estava definido nos contratos 0.2.0 e seu schema continua gerado.

O gate E0 continua pendente: o rig NH-TEST (#22) e a revisão integrada GATE-E0 (#38) ainda são necessários antes de E1. Nenhum domínio das RFCs futuras foi implementado.

## Commits preservados e correções de revisão

Os seis commits prévios da lane permanecem intactos. Correções nesta retomada:

- `efc2804` — validação recursiva JS/Swift, unions discriminadas e corpus comum, incluindo cobertura por operação.
- `6562379` — decisão explícita para `runtime.dispatch`, TTL local de 900000 ms e validação da expiração inclusiva.
- `6a5ae11` — distinção entre base documental, ancestral integrado e estado parcial para revisão.
- `495abf0` — limites e condições específicas das operações, incluindo campos de caminho, URLs, branches, dados base64 decodificados e variantes MCP.

Arquivos desta retomada: `src/harness/contracts/{validate.mjs,validate.test.mjs,harness-v1.schema.json,corpus-v1.json,operation-registry.json}`, `src/harness/local-host.{mjs,test.mjs}`, `Sources/PocketWikiMac/Models/Harness/{HarnessV1.swift,HarnessOperationRegistry.swift}`, `Tests/Harness/HarnessV1CorpusRunner.swift`, `scripts/generate-harness-{registry.mjs,schemas.py,operation-corpus.mjs}`, `scripts/test-harness-contracts-swift.sh`, `package.json` e os documentos NH-00 listados acima. PocketKernel e MiddlewareAuth não receberam alterações nesta retomada.

## Evidência desta revisão

- Antes da correção, o validador JS aceitava `NH00-PERM-002` e `NH00-FORGE-002` embora esperassem rejeição.
- Antes da correção, o runner Swift aceitava `NH00-SNAP-004`, `NH00-SNAP-005` e `NH00-STREAM-004` com conteúdo inválido aninhado.
- Antes da correção por operação, JS e Swift aceitavam seis casos inválidos de path, branch, limite decodificado, endpoint HTTP remoto e campos de mutação em MCP list.
- Depois: `npm run generate:harness-contracts` gera 232 slots para as 50 operações; `npm run test:harness-contracts` passa com 9 testes JS e 280 slots comuns Swift; `npm test` passa; `swift build -c debug` passa.
- Kernel, sem mudanças nesta retomada: `CGO_ENABLED=0 go test ./...` passa e `sh script/build_nh00_matrix.sh` compila Linux arm64/amd64 sem CGO.

## Integração

1. Em PocketWiki, aguarde a integração do PR documental #45 (`5311a8aae2876c572f25b79540f38ee0acac7121`), baseado no ancestral `main` `7703ac708120d93f54c7d29c5ad34dde9591a1bf`; depois integre a lane `codex/nh-e0-nh00` posterior à base documental.
2. Em PocketKernel, crie a branch de integração a partir de `02fe052516a3bd53f4fab4d94cd566540bce276c` e aplique `ff32bbc9f386ef4f4be55da281c481d79a4a5299`.
3. Registre os dois SHAs de integração e o SHA MiddlewareAuth acima na issue #21; mantenha MiddlewareAuth sem alterações nesta etapa.
4. Rode `npm run generate:harness-contracts`, `npm run test:harness-contracts`, `npm test`, `swift build -c debug`, `CGO_ENABLED=0 go test ./...` e `sh script/build_nh00_matrix.sh`. Esta entrega ainda aguarda revisão; NH-TEST só recebe a base depois do aceite, e E1 depende do rig e do GATE-E0 aprovados.
