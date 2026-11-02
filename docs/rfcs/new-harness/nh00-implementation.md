# NH-00 — registro de implementação e evidências de aceite

## Estado da entrega

A revisão de aceite desta rodada concluiu: **APROVADA pelos AC-01…AC-08**, com evidências na árvore final abaixo. A base imutável pode seguir para NH-TEST. Isso aprova somente NH-00: não fecha o gate E0 e não afirma E2E de produto.

A base documental da lane é PocketWiki `5311a8aae2876c572f25b79540f38ee0acac7121`, branch `codex/new-harness-rfcs`; esse commit ainda não foi integrado a `main` (PR #45 aberto). A base integrada de código, ancestral comum com `main`, é `7703ac708120d93f54c7d29c5ad34dde9591a1bf`. A implementação continua empilhada sobre a base documental, conforme autorizado. Não chamar `5311a8a` de integrada.

## Revisão de aceite

| AC | Evidência executada na árvore final | Resultado técnico |
|---|---|---|
| AC-01 | `npm run test:harness-contracts`; `sh scripts/test-nh00-acceptance.sh`; os 910 slots comuns e 13 regressões independentes (923 IDs únicos) passam nos dois runtimes | Atendido; zero skips/divergências |
| AC-02 | `docs/rfcs/new-harness/nh00-matriz-cobertura.md`; gerador `scripts/generate-nh00-coverage-matrix.mjs` | Atendido; 50 operações, 46 entidades, 15 snapshots e 54 variants de evento relacionados a IDs e resultados JS/Swift; R1–R5 e omissões explícitos |
| AC-03 | Corpus comum + regressões; bordas e imediatamente além, UTF-8 multibyte, base64 decodificado, JSON safe integer, bool/int, optional/null, PermissionAction e MCP por `tool` | Atendido |
| AC-04 | `contratos-integracao-v0.2.md`, schemas e IDs `AC-runtime-dispatch-*`; `local-host.test.mjs` valida `expiry-1` e `expiry`, restart/revoke também na integração AC-05 | Atendido; igualdade de campos duplicados obrigatória; divergência `ERR_INVALID` pré-efeito; TTL inclusivo de 900000 ms |
| AC-05 | `npm run test:nh00-bootstrap` — processos separados PocketWiki host e probe Go Kernel, socket Unix privado mode 0600 e store temporário | Atendido; allow scoped passa; principal/environment/audience/scope/agregado incorretos, ausente, expirado, revogado, falha de entrega e restart negados antes de efeito; persistência hash-only |
| AC-06 | `validate.test.mjs`: mismatch de classe retorna `ERR_INVALID`; capacidades vazias; schemas futuros presentes; operação futura e protocolo major desconhecido recusados | Atendido; nenhuma capability anuncia handler não implementado/habilitado/validado |
| AC-07 | `CGO_ENABLED=0 go test ./...`; `sh script/build_nh00_matrix.sh`; `npm run test:nh00-chromium` | Atendido; builds Linux arm64/amd64 sem CGO; Playwright 1.64.1, Chromium revision 1248 / Chrome 156.0.8078.4, headless `file://`, marker local, sem sleeps/rede externa |
| AC-08 | `npm run generate:harness-contracts` duas vezes, comparação de hashes de saída; `npm test`; `swift build -c debug`; demais comandos acima | Atendido; geração determinística, suites sem skip e builds passaram. SHA e hashes abaixo identificam esta árvore |

**Veredito da revisão:** APROVADA para encaminhar o snapshot PocketWiki identificado abaixo a NH-TEST. A aprovação não integra branches, não fecha gate E0 e não inclui LEGACY-00 como executado por NH-00.

## Contratos e escopo

- Schemas fechados para envelopes, 46 entidades, 15 snapshots, eventos de módulos, PermissionAction/ForgePreview e inputs de operação. JS e Swift validam recursivamente o mesmo schema/corpus.
- Corpus: 910 slots compartilhados — 48 casos preexistentes preservados, 396 estruturais (snapshots, entidades e eventos) e 466 de operação — mais 13 regressões independentes em `Tests/Harness/nh00-acceptance-regressions.json`.
- Limite condicional: `ConversationMessage.content` respeita bytes por `role`; `ContextSegment.content_base64` limita bytes codificados e decodificados; campos de texto de R1 têm os limites normativos. Arrays e inteiros têm bordas revisadas. `PermissionRequest.options` tem `maxItems: 100`, mas coincide com `PermissionAction.question.options`, limitado a 10; limite semântico efetivo é 10, coberto em 10/11.
- `runtime.dispatch` preserva o wire repetido. `input.command_id` e `input.expected_revision` devem ser iguais ao envelope; mismatch é inválido antes de qualquer efeito. A decisão está no contrato normativo e nos testes independentes.
- Bootstrap local usa bearer aleatório de 32 bytes, canal host→Kernel privado, principal/environment/audience/scopes/agregado vinculados, TTL de 900000 ms e `expires_at_ms` em metadata privado. Só hash e metadados autorizados persistem. Falha de entrega revoga; reiniciar Kernel não restaura credenciais. MiddlewareAuth remoto não é modificado nesta etapa.
- Registry tem 50 operações com owner/classe/schema/slot. Não há handlers E0 anunciáveis; `listCapabilities()` fica vazio. Schemas de operações futuras continuam presentes, sem implementar domínios futuros. Adapter Codex continua indisponível: não há adapter nem transcrição sanitizada validada; o teste de capabilities impede anunciar `agent`.
- APIs legadas `/v1/kernel`, `/api/memory/*` e MCP Evidence foram preservadas.

## Commits da revisão

PocketWiki, branch `codex/nh-e0-nh00`, mantém os commits anteriores intactos. Correções e entregas desta retomada:

- `f01219f` — critérios e regressões independentes antes da correção.
- `7547d7c` — cursor opcional ausente aceito; null recusado.
- `cd767b1` — cobertura estrutural e por operação ampliada;
- `9511b7d` — limites recursivos e corpus de entidade alinhados entre JS/Swift.
- `83e1e11` — bootstrap scoped integrado a processo Kernel.
- `945d01d` — matriz de cobertura e smoke isolado do Chromium.
- `89f0845` — despacho por classe incompatível testado.
- `e240155` — ausência de singletons obrigatórios em snapshots coberta.
- `97b3db7` — integração comprova que bearer não aparece em URL nem nos logs dos processos.

PocketKernel mantém histórico separado, branch `codex/nh00-locks`: `b17f3b5` verifier/ACL scoped e `03f8f30` encerramento limpo do probe de teste. MiddlewareAuth não recebeu alterações.

## Comandos e resultados

| Comando | Resultado |
|---|---|
| `npm run generate:harness-contracts` ×2 | exit 0 em ambos; mesmos hashes de schema/corpus/matriz antes e depois |
| `npm run test:harness-contracts` | exit 0; 12 testes JS passaram, 910 slots Swift passaram, 0 skips |
| `sh scripts/test-nh00-acceptance.sh` | exit 0; 923 IDs únicos; resultados JS comparados individualmente com `accept`, runner Swift aprovou 923 slots |
| `npm test` | exit 0; suites legadas Solutions, MCP, Graph, Excalidraw Desktop e Memory passaram, sem skips |
| `swift build -c debug` | exit 0 |
| `npm run test:nh00-bootstrap` | exit 0; integração real entre processos aprovada |
| `CGO_ENABLED=0 go test ./...` | exit 0 |
| `sh script/build_nh00_matrix.sh` | exit 0; Linux arm64 e amd64 sem CGO |
| `npm run test:nh00-chromium` | exit 0; revision 1248 isolada, página local/marker aprovados |

O runner de aceitação mescla o corpus compartilhado e os fixtures independentes, rejeita IDs duplicados e aplica os mesmos slots a JS e Swift. Uma execução AC-05 anterior imprimiu aprovação mas ficou pendurada por cleanup incorreto; foi descartada. Após corrigir o cleanup e o encerramento do probe, a execução acima terminou com exit 0.

## SHAs, hashes e arquivos preexistentes

- PocketWiki snapshot de implementação validado antes do commit deste relatório: `97b3db728f216e1ab29d1b5d3327637ffa521208`; branch `codex/nh-e0-nh00`. O commit posterior deste relatório é identificado no resumo da revisão.
- Base documental PocketWiki: `5311a8aae2876c572f25b79540f38ee0acac7121` (não integrada).
- Base integrada de código / ancestral comum: `7703ac708120d93f54c7d29c5ad34dde9591a1bf`.
- PocketKernel final: `03f8f30eb781b4d16a9dca76f7548f9781bbef02`, branch `codex/nh00-locks`.
- MiddlewareAuth observado: `04f44f62126c785f7b28718d2eff837c28cb65df`, branch `main`, sem alterações.
- SHA-256 schema `harness-v1.schema.json`: `306915400385fa9bd7c22096fb18228d4d2c02e0f272376f8c2c5ebd7bebae70`.
- SHA-256 corpus `corpus-v1.json`: `9aef5fbe89e3d129ebcf54a8dab048780ba1bb65519c0e8d1eb607846b107ef9`.
- SHA-256 matriz cobertura: `e714613c631b68f0a62837693c6387988483481b1045250a6eb956b9daebd871`.
- SHA-256 `package-lock.json`: `2d950a0e6ac2a855d215c723abc8173e58ffcd8c39a1732699632d956d0ed01c`.
- SHA-256 Kernel `go.mod`: `73d61aeb664dfb8b1df7dd6aba79bf85f1121a11a39062147d1816181b617f50`.
- SHA-256 Kernel `go.sum`: `1692bb6aa37ae13a36b6629bf65d910085c99c221f5bd7569b001ddee5b6e2d2`.
- SHA-256 registry de operações `operation-registry.json`: `7e2bf3e98a8fc147ec1237f4896c0bc5f803143a5770d152ff270e0d9d795159`.
- SHA-256 regressões independentes: `3633ded68d693060fc10468785630435b5ae27d423d95196b5f533f78da3429f`.
- Arquivo não rastreado preexistente preservado no PocketWiki: `src/harness/registry 2.mjs`; não foi incluído nem alterado.
- Arquivos não rastreados preexistentes preservados em MiddlewareAuth: `docs/CLIENT_TOKEN_ROTATION 2.md`, `docs/DECISION_PROVIDER_CONTRACT 2.md`, `internal/auth/client_token 2.go`, `internal/auth/client_token_test 2.go`; não foram incluídos nem alterados.

## Integração posterior

A lane PocketWiki continua empilhada sobre o SHA documental `5311a8a`; primeiro integre/reconcilie PR #45 e depois aplique a lane sem alterar a base reportada. Integre separadamente o branch/commit PocketKernel no repositório correto. MiddlewareAuth não tem commit nesta etapa. Só após aceite desta revisão entregue o SHA PocketWiki imutável a NH-TEST. LEGACY-00 permanece NH-TEST/gate E0; não é declarado executado aqui.
