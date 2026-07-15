# API de ingestão de soluções do PocketTrace

- Versão: `pocketwiki.solutions.write.v1`
- Endpoint: `PUT /api/v1/solutions/{solution_id}`
- Schema aceito: `pockettrace.pocketwiki_solution.v1`

Este é o contrato canônico implementado pelo PocketWiki para o cliente `pocketwiki_push` do PocketTrace.

## Headers

```http
Authorization: Bearer <token>
Content-Type: application/json
Accept: application/json
Idempotency-Key: <solution_id>:<document_version>
If-Match: <remote_revision>
```

`If-Match` não é enviado na criação e é obrigatório para atualizar uma solução existente. O bearer é provisionado fora do repositório por `POCKETWIKI_WRITE_TOKEN`. `POCKETWIKI_REFERENCE_READONLY=true` bloqueia escrita. Sem token configurado, o endpoint falha fechado com `503`.

O request tem limite padrão e mínimo operacional de 8 MiB. `POCKETWIKI_WRITE_MAX_BYTES` pode apenas aumentá-lo. `body_markdown` aceita no máximo 5 MiB.

## Corpo

```json
{
  "schema_version": "pockettrace.pocketwiki_solution.v1",
  "generator_version": "pockettrace.processor.v1",
  "input_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "output_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "solution_id": "solution_demo",
  "document_version": "doc_v1",
  "trace_or_context_id": "pt_example",
  "title": "Configurar observabilidade",
  "summary": "Runbook revisado para configurar observabilidade.",
  "body_markdown": "# Configurar observabilidade\n\nConteúdo revisado.",
  "category": "infraestrutura",
  "tags": ["observabilidade", "macos"],
  "replicability_level": "R2",
  "mvp5_candidate": false,
  "source_hashes": [
    {
      "path": "ai/runs/example/validated_output.json",
      "artifact_type": "ai_validated_output_json",
      "schema_version": "pockettrace.ai_validated_enrichment.v1",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
  ],
  "publish_mode": "ai_enriched"
}
```

Regras de validação:

| Campo | Regra |
|---|---|
| `schema_version` | exatamente `pockettrace.pocketwiki_solution.v1` |
| `generator_version` | string não vazia, até 200 caracteres |
| `input_hash`, `output_hash` | SHA-256 lowercase |
| `solution_id` | igual ao path e compatível com `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$` |
| `document_version`, `trace_or_context_id` | string não vazia, até 200 caracteres |
| `title` | string não vazia, até 500 caracteres |
| `summary` | string não vazia, até 4.000 caracteres |
| `body_markdown` | UTF-8 não vazio, até 5 MiB |
| `category` | `null` ou string de até 200 caracteres |
| `tags` | até 50 strings de até 80 caracteres |
| `replicability_level` | `R0`, `R1`, `R2` ou `R3` |
| `mvp5_candidate` | boolean |
| `source_hashes` | array não vazio com `path`, `artifact_type`, `schema_version` e `sha256` |
| `publish_mode` | `ai_enriched` ou `deterministic_only` |

Para validar `output_hash`, o servidor substitui esse campo por string vazia, ordena recursivamente as chaves do objeto, serializa JSON UTF-8 compacto sem escapar `/` e calcula SHA-256. Divergência retorna `422` com `error=output_hash_mismatch`.

## Persistência e concorrência

O documento é persistido atomicamente em `solutions/{solution_id}.md`. Os metadados ficam em frontmatter e o corpo Markdown é preservado como dado não confiável. O path nunca vem do request. `source_hashes.path` é apenas proveniência textual e não é resolvido no servidor.

A revisão forte usa o formato `"sha256:<64-hex>"` sobre os bytes completos do Markdown persistido. Criação sem `If-Match` retorna `201`. Documento existente sem `If-Match` retorna `409`. Atualização com revisão atual retorna `200`; revisão divergente retorna `412` e inclui a revisão corrente.

O store de idempotência fica em `.pocketwiki/solution-idempotency/`, fora do índice de leitura. Ele guarda somente hash do request e response lógica, sobrevive a restart e não expira automaticamente. Repetir chave e payload devolve o mesmo resultado sem reescrever. Reusar a chave com outro payload retorna `409 idempotency_key_reused`.

A gravação usa temporários no mesmo filesystem e rename. Documento e registro de idempotência são verificados após persistência; falha de escrita ou indexação aciona rollback e retorna `500` sem confirmar a chave.

## Responses

Sucesso retorna `ETag` e:

```json
{
  "remote_id": "solution_demo",
  "remote_revision": "\"sha256:0123456789abcdef...\"",
  "message": "created"
}
```

Em atualização, `message` é `updated`. Conflitos incluem `remote_id`, `remote_revision`, `error` e `message`.

| HTTP | `error` |
|---:|---|
| 400 | `invalid_request` |
| 401 | `unauthorized` |
| 403 | `write_disabled` |
| 404 | `reference_unavailable` |
| 409 | `remote_conflict` ou `idempotency_key_reused` |
| 412 | `remote_revision_mismatch` |
| 413 | `payload_too_large` |
| 415 | `unsupported_media_type` |
| 422 | `schema_validation_failed` ou `output_hash_mismatch` |
| 500 | `write_failed` |
| 503 | `write_unavailable` |

Todas as responses são JSON compactas, usam as security headers do servidor e não ecoam token nem Markdown integral.

## Operação

O PocketTrace exige HTTPS. Na LAN/tailnet, exponha o servidor local por Tailscale Serve ou reverse proxy HTTPS:

```sh
tailscale serve --bg http://127.0.0.1:8787
tailscale serve status
```

Smoke tests de criação e atualização estão no README. A suíte automatizada é executada com:

```sh
npm run test:solutions
```
