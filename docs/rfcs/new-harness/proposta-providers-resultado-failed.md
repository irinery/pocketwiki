# Proposta para resultado `failed` de providers

Status: proposta para revisão, não normativa. Não altera R1, registry, schemas,
implementação, gates ou `Ready`. Não autoriza deploy nem migração. O objetivo é
resolver o caso de `providers.select`; execução direta de inferência e runs não
são comandos novos desta proposta.

## Lacuna atual

A [arquitetura](arquitetura-e-implementacao.md) § Contratos transversais define
`CommandReceipt.state=failed`, manda erros de domínio no resultado, POST novo
202, duplicata 200 e GET de `result_ref` com saída tipada. A [RFC 0003/01](0003-providers-capabilities.md)
ao mesmo tempo atribui HTTP 503/409/422 a `ERR_PROVIDER_UNAVAILABLE`,
`ERR_CATALOG_STALE` e `ERR_UNSUPPORTED`. O schema atual define `HarnessError` e
`httpCommandReceipt`, mas não define um resultado de falha para
`providers.select`: `$defs.providers.select` descreve a entrada, não a saída.
O contrato também não determina se uma falha sem alteração de provider consome
revision, seq ou evento. Não há base para escolher esses detalhes em produção.

## Recomendação de wire

Depois da decisão e atualização normativa, manter o sucesso GET existente:

```json
{"binding_id":"11111111-1111-4111-8111-111111111111","capabilities":{"version":1,"stream_text":false,"steer":false,"interrupt":false,"rollback":false,"native_fork":false,"tools":false,"questions":false,"plans":false,"resume":false,"capability_id":"22222222-2222-4222-8222-222222222222"},"catalog_revision":1}
```

Para `GET /v1/harness/results/{result_ref}` de um receipt `failed`, propor HTTP
200, `Cache-Control: no-store` e um objeto fechado distinto, sem campos de
sucesso:

```json
{"error":{"code":"ERR_CATALOG_STALE","message":"Catálogo desatualizado","correlation_id":"33333333-3333-4333-8333-333333333333","retryable":false}}
```

O `error` é `HarnessError` fechado: enum aplicável abaixo, mensagem redigida de
até 1024 bytes, UUID canônico e boolean. O discriminador é a presença exclusiva
de `error`; sucesso não o contém, falha não contém `binding_id`, `capabilities`
ou `catalog_revision`. `result_ref` só é emitido após commit do resultado
terminal. O cliente consulta primeiro o receipt ou recebe seu estado no POST;
não deduz falha só de uma resposta GET parcial. Resultados de comandos de
outras operações continuam com os próprios schemas.

Para falha de domínio confirmada e persistida, POST novo devolve 202 e receipt
`state=failed`; mesmo ID e hash devolvem 200, `duplicate=true` e o mesmo receipt
(incluindo revision e result_ref). GET do resultado devolve o mesmo erro lógico,
inclusive `correlation_id` e bytes canônicos, após autorização atual. Esta
proposta resolve o conflito a favor do contrato transversal: os 503/409/422 da
RFC para essas três condições deixam de ser status do POST **somente depois**
da alteração normativa coordenada. A idempotência do mesmo `command_id`/hash
é obrigatória independentemente do valor de `retryable`. O flag sugere se uma
nova intenção explícita, com novo ID, pode fazer sentido após refresh ou reparo;
não garante disponibilidade e não autoriza criar essa intenção automaticamente.

## Fronteira entre falha terminal e indisponibilidade

Só registrar `failed` quando a preparação terminou com diagnóstico inequívoco
do domínio, após autenticação, validação e consulta de conta, e a transação
conseguiu confirmar a falha. A lista fechada proposta é:

- `ERR_CATALOG_STALE`: revisão pedida não corresponde ao catálogo confirmado.
- `ERR_UNSUPPORTED`: capability ou modo não é publicado para aquela seleção.
- `ERR_PROVIDER_UNAVAILABLE`: adapter/login/binário explicitamente indisponível
  segundo diagnóstico tipado e confiável da fronteira; não deduzir a classe
  comparando texto nem usar erro genérico de rede já colapsado.

Formato inválido, major incompatível, falta de autoridade, conflito CAS/hash,
limite e rate limit continuam erros HTTP da fronteira, sem receipt novo. Erro
indeterminado de rede, cancelamento, timeout, perda de commit ou falha do store
não vira `failed` conhecido: responder erro de fronteira permitido, sem inventar
resultado. Se o cliente não sabe se houve commit, consulta receipt pelo mesmo
ID; em caso de indisponibilidade preserva o estado e não troca o ID
silenciosamente. Resposta 404, epoch revogado ou retenção expirada tampouco
prova ausência de commit e não autoriza trocar o ID automaticamente. Nenhum
timeout sozinho prova que o outro lado não fez I/O.

A preparação de `providers.select` deve ser somente consulta/handshake: não
executar prompt nem lançar efeito que dependa de exactly-once. Esta proposta
não afirma que rede, cliente externo ou execução direta de inferência são
idempotentes. Antes do commit, dois pedidos concorrentes podem preparar a mesma
seleção; não há claim de uma única chamada ao adapter. Se no futuro preparar
passar a produzir efeito externo não reversível, ela exige protocolo durável
próprio e reconciliação, não retry automático baseado nesta proposta.

## CAS, revisão, seq e replay

Recomendação para uma falha **sem mudar a seleção confirmada, bindings ou
capabilities**, e sem avançar a revision ou seq do environment na transação de
falha. A preparação autorizada pode já ter persistido tracking de catálogo
(`TrackCatalogTx`), inclusive digest/revisão próprios, antes do diagnóstico;
a proposta não promete desfazer esse tracking nem que todo estado auxiliar
permaneceu inalterado:

1. Preflight valida command, owner/scope, grant da conta, expected revision e
   replay existente antes de consultar catálogo/adapter. Falta de autoridade
   rejeita antes do I/O. A preparação ocorre fora dos locks, com binding de
   principal, environment, conta e geração capturados para revalidação.
2. No writer serializado, revalidar autoridade atual, geração/epoch e índice;
   verificar primeiro replay existente e seu hash, mesmo se a revision atual
   já tiver avançado. Primeiro commit de um command_id/hash prevalece: o
   concorrente retorna o mesmo receipt, ainda que sua preparação tenha outro
   diagnóstico; hash diferente é conflito. Só para comando ainda inédito,
   revalidar CAS. Se a revision mudou durante a preparação, responder 409
   `ERR_CONFLICT` sem criar receipt nem registrar o diagnóstico antigo. Não
   converter esse conflito em falha de domínio.
3. Na mesma transação gravar receipt terminal `failed`, `result_ref`, resultado
   fechado, hash/correlação e proveniência imutável de principal, environment,
   conta, epoch e peer de submissão, derivados da entrada validada. Falha não
   tem binding_id: não inventar UUID nem fazer join com binding de outra
   seleção. Não gravar `ProviderBinding` ou
   `ProviderCapabilities`, nem mudar a seleção confirmada.
4. A revision do receipt é a revision atual validada pelo CAS; **não** avança a
   revision de environment, e seq não avança. O receipt e o resultado são
   metadados de comando consultáveis por ID/referência, não uma entidade nova de
   `FeatureSnapshot` ou evento providers. Vários receipts podem compartilhar
   revision. Não emitir `RuntimeReceipt` de thread em um environment nem
   inventar `ModuleEvent`. Essa exceção precisa ser aprovada explicitamente no
   contrato, porque o ledger candidato atual exige changes e incrementa revision.
5. Uma leitura exige credencial `read`, owner/environment corretos e grant de
   conta atual. O leitor autorizado não precisa ser o peer que submeteu, mas a
   origem imutável precisa ser íntegra. Revogar e conceder a mesma conta de novo
   não revive resultado de epoch anterior. O replay de POST exige `submit`,
   mesma proveniência de comando/peer e validação de hash e epoch; não invoca
   catálogo/adapter. Revogação entre preparação e commit impede o commit;
   revogação antes do flush impede nova publicação local.
6. Publicar receipt ou resultado apenas depois de commit confirmado e de nova
   checagem de autoridade, mantendo guardas até `Write` e `Flush` com prazo. Um
   erro depois de bytes iniciados aborta o transporte; bytes já aceitos pelo
   kernel podem chegar depois da revogação. Perda da resposta não desfaz commit.

O registro failed sem evento é uma decisão proposta, não uma garantia dos
contratos atuais. Se o produto exigir que a falha apareça por stream/snapshot,
será preciso primeiro especificar entidade, módulo/agregado, ACL, eventos e
revisão — não reutilizar silenciosamente a entidade runtime de thread.

## Aceite e mudanças posteriores à decisão

- Atualizar arquitetura/R1 e RFC 0003 em conjunto, inclusive tabela de status,
  sem alterar o significado de erros de transporte. Registrar explicitamente
  a exceção revision/seq para receipt failed sem mudança da seleção confirmada.
- Adicionar schemas fechados de sucesso e falha e união discriminada por forma,
  exemplos e corpus positivo/negativo; validadores JS e Swift precisam rejeitar
  campos misturados, códigos fora da lista, null indevido e UUID inválido.
  Validar `failed` com `result_ref` obrigatório e shape `error`; `succeeded`
  exige `SelectionResult`. HTTP 200 do GET sozinho não indica sucesso. Um
  primeiro failed pode ter revision 0: criar ramo explícito para ele, sem
  passar pela validação legada de sucesso que exige revision >= 1.
  Implementar também os transportes e validadores providers JS e Swift para
  POST/receipt e a união de resultados; os clientes atuais de providers não
  fazem esse fluxo e `runtimeDispatchResult` não é substituto.
  Como failed não avança revision/seq, ordenar por esses números não basta:
  associar receipt/result_ref/command_id a um ticket da tentativa local e
  à autoridade vigente. Resposta antiga após nova seleção, refresh ou reauth não sobrescreve
  draft, erro ou estado atual. Testar duas falhas em revision 0 recebidas em
  ordem inversa e falha antiga chegando depois de sucesso ou reauth.
- Definir política explícita de admissão, limites e retenção de receipts e
  resultados failed, e o que ocorre após GC. Preservar tombstone/índice e hash
  de command suficiente para impedir reexecução do mesmo ID após perda do corpo;
  não inventar TTL nem tratar resultado removido como comando nunca aceito.
  Retenção insuficiente ou evidência ausente deve falhar fechado.
- Projetar migração versionada e seal/proveniência para receipts failed sem
  backfill por inferência; bancos antigos ficam fail-closed até migração testada.
  Nunca fazer `failed` passar pelo caminho legado que assume `succeeded`.
- Testar cliente/servidor reais e processos: cada erro terminal; erros de
  transporte sem receipt falso e diagnóstico typed distinto de erro genérico
  de rede; failed revision 0, vinculação state/shape e retention/GC sem replay;
  CAS concorrente; mesmo ID/hash concorrente e
  conflito hash; perda de resposta após commit e GET/replay sem novo adapter;
  falha de commit com rollback integral; concorrência entre commits sucesso e
  falha; revoke/regrant em preparação, commit e publicação; leitores/principais
  e epochs distintos; tentativa de trocar result_ref, output ou provenance;
  expiração/EOF/Flush; restart e compatibilidade de schema. Comprovar ausência
  de qualquer novo binding/evento providers e invariância de revision/seq.
- Manter diagnóstico sensível fora de `message`, logs e artefatos. Falha de
  política, schema, retenção ou autorização deve negar; não usar fixture como
  evidência do serviço real. Revisão, matriz cumulativa e infraestrutura de UID
  dedicado continuam separadas desta decisão.
