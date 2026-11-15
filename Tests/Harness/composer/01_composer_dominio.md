# RFC-0005/01 — Contrato de domínio do composer E2

Base PocketWiki `d98f09bc4ae667c96c093c9f0b09134326ebb435`; PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`; MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`. A RFC `docs/rfcs/new-harness/0005-composer-contexto.md` versão 0.2.0 e o cabeçalho R1–R7 em `docs/rfcs/new-harness/contratos-integracao-v0.2.md` são normativos. Este arquivo é o artefato da lane para revisão; o integrador decide sua colocação no diretório compartilhado de contratos. As lacunas no handoff impedem declarar a fase concluída.

## Autoridade e operações

PocketWiki é autoridade do contexto. Identidade, environment, thread, scopes e audience vêm de credencial verificada, e não de campos escolhidos pelo cliente. Em mutation, host aplica `HarnessCommand` major 1, `command_id`, CAS por `expected_revision`, receipt e idempotência do Kernel. Leituras não criam receipt. Conteúdo anexado é sempre `untrusted_content`; pergunta e segmentos são distintos.

| Operação | Entrada fechada | Sucesso |
| --- | --- | --- |
| `composer.stage` | `thread_id`, `filename` basename, `mime`, `content_base64` | `reference` |
| `composer.draft.save` | `draft: ComposerDraft` | `draft_id`, `revision` |
| `composer.prepare` | `thread_id`, `draft_id`, `text`, `references`, `context_budget_bytes` | `prepared_id`, `manifest`, `included_bytes`, `manifest_sha256`, `expires_at_ms` |
| `composer.resolve` | `prepared_id`, `manifest_sha256`; identidade delegada no transporte | `context: PreparedContext` |
| `composer.pin` | `prepared_id`, `command_id`, `retain` | `retained` |

Campos e tipos recursivos são os de `harness-v1.schema.json`: `ContextReference`, `ComposerDraft`, `ContextSegment`, `PreparedContext` e snapshot `composer`. Referências contêm UUID, kind fechado wiki/file/quote/image, hash SHA-256 dos bytes, tamanho, trust e origem relativa/message_id opcionais. `PreparedContext` inclui identidade, pergunta, manifesto, segmentos, hash e expiração; ID e hash nunca autorizam leitura. O hash do manifesto é SHA-256 sobre JCS RFC 8785 de `{environment_id,thread_id,principal_id,text,manifest}`.

## Limites e recuperação

Até 20 referências, 4 MiB agregados em staging, 1 MiB por texto, 2 MiB por imagem, pergunta de 1–32768 bytes e budget de contexto 1024–65536 bytes. Sem truncamento; contexto fora do orçamento retorna `ERR_BUDGET`. MIME fechado text/plain, text/markdown, image/png, image/jpeg. Stage tem deadline de 30000 ms, stash e prepared sem pin duram 86400000 ms; pin idempotente por command_id protege bytes enquanto a intenção existir. Retain=false é idempotente após liberação. A verificação de capability do adapter pertence a threads em E3, não a E2.

Erros de domínio fechados: `ERR_INVALID`, `ERR_FORBIDDEN`, `ERR_TIMEOUT`, `ERR_UNAVAILABLE`, `ERR_INCOMPATIBLE`, `ERR_CONTEXT_STALE`, `ERR_BUDGET`, `ERR_PATH_ESCAPE`, `ERR_UNSUPPORTED`. Snapshot acrescenta `ERR_CURSOR_EXPIRED`. Erro contém code, message redigida até 1024 bytes, correlation_id e retryable. Falha não altera draft confirmado; em mutação ambígua consultar receipt.

Snapshot é projeção persistida, nunca resposta de comando. Fixa snapshot_id/revision/as_of_seq e ordena entidades por ID; cursor opaco limitado a 512 bytes, vinculado à identidade, page_size e snapshot, TTL 600000 ms, até 100 entidades e 4 MiB por página. Última página omite next_cursor. Cliente instala todas páginas atomicamente, aplica eventos posteriores deduplicados e reinicia após `ERR_CURSOR_EXPIRED` sem perder edição local. Retenção de eventos precisa cobrir a boundary durante o TTL.

## Wiring e evidência

`ComposerGateway` autentica `LocalCredentialHost` E1 e `ComposerPolicy` concede principal/environment/thread/roots. `ComposerService` opera stash privado e exige helper `secure-read` instalado por caminho confiável para leitura ancorada. O host precisa ligar ledger/receipts e o resolver de fontes autorizado sem aceitar identidade, roots ou caminho do helper do payload. A sequência de comandos e resultados, bem como testes e limitações ainda abertas, estão em `SERVICE-0005.md`. Nenhum teste isolado desta lane aprova gate cumulativo ou CONTEXT-CHAIN.
