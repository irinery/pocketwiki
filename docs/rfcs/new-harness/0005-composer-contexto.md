# RFC — Composer com contexto, anexos e citações

**Projeto:** PocketWiki / New Harness. (RFC-0005)
**Data:** 2026-11-01
**Issue:** [#26](https://github.com/irinery/pocketwiki/issues/26)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
Há seleção de arquivos e contexto da wiki, mas falta um manifesto de contexto auditável e estável por envio, com limite por bytes e citações endereçáveis.

### 1.2 Solução
Transformar cada envio em texto do usuário mais referências verificadas de contexto, sem transformar documento anexado em instrução.

O recorte desta RFC é: Draft por thread, anexos texto/PNG/JPEG, referências de página/arquivo/trecho, citação com hash e preview do contexto selecionado; stash local sem upload implícito.

### 1.3 Fora de escopo
Vídeo, áudio, editor rich text completo, executar instruções de anexos, permitir arquivos fora dos roots concedidos.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketWiki. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/user/composer.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/composer.md)
- [docs/internals/composer-context-references.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/composer-context-references.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_composer_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_composer_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/composer/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

### Convenções globais
- PocketWiki é autoridade deste domínio; PocketWiki não lê store privado de integração externa.
- Auth por principal/environment + scope a cada ação. IDs de request e hashes não são credenciais.
- Erro de domínio serializa como `HarnessError {code:string, message:string, correlation_id:uuid, retryable:bool}`; message máximo 1024 bytes e redigida, code limitado à lista da fase.
- APIs propostas ficam sob `/v1/harness` no Kernel e `/api/harness` na fachada PocketWiki; o identificador canônico abaixo é a operação de domínio. E0 materializa o mapa da arquitetura e contratos-integracao-v0.2.md, sem decisões implícitas.
- Limites bytes são bytes UTF-8; limites em caracteres são Unicode scalars. Strings gerais 4096 bytes e arrays gerais 100 itens, salvo regra específica.

### Definition of Done global
- [ ] todos os cenários numerados das fases 01 e 02 executados através de interfaces reais
- [ ] JS e Swift aceitam/rejeitam o mesmo corpus de contratos
- [ ] revisão humana/técnica e E2E cumulativo no SHA integrado da etapa
- [ ] sem regressão em memória/sessões v1, wiki, MCP Evidence e modo externo
- [ ] nenhum secret em fixtures, logs, UI ou export

## 3.1 — Fase 01: Domínio e persistência

### O que é
Transformar cada envio em texto do usuário mais referências verificadas de contexto, sem transformar documento anexado em instrução. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Draft por thread, anexos texto/PNG/JPEG, referências de página/arquivo/trecho, citação com hash e preview do contexto selecionado; stash local sem upload implícito.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Vídeo, áudio, editor rich text completo, executar instruções de anexos, permitir arquivos fora dos roots concedidos.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02.

**Posse de arquivos:** PocketWiki: `src/harness/composer/`, `Sources/PocketWikiMac/Services/Harness/Composer/`, `Tests/Harness/composer/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: wiki e quote válidos dentro do budget
quando: preparar e consultar manifesto
então: hash, origem e bytes exatos expostos ao usuário

TESTE 01-02 [falha]
dado: arquivo muda entre preview e envio
quando: preparar
então: ERR_CONTEXT_STALE e draft intacto

TESTE 01-03 [edge case]
dado: UTF-8 multibyte no limite de bytes
quando: preparar
então: conta bytes corretamente sem cortar caractere

TESTE 01-04 [segurança]
dado: symlink fora do root e anexo dizendo ignore as regras
quando: preparar
então: symlink rejeitado; texto permitido permanece untrusted_content e não eleva permissões

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

TESTE 01-06 [integração]
dado: contexto preparado com anexo autorizado e referência excluída
quando: pin por command_id, avançar TTL e resolver com identidade delegada correta e incorreta
então: bytes/hash imutáveis sobrevivem com pin, excluído ausente e outra identidade recebe ERR_FORBIDDEN; após unpin e TTL ocorre ERR_CONTEXT_STALE

```

### Contratos de interface

```yaml
interface:
  id: IF-0005-01-1
  tipo: function
  nome: "composer.prepare"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizado"
    - campo: draft_id
      tipo: "uuid"
      obrigatório: true
      validação: "ID local estável"
    - campo: text
      tipo: "string"
      obrigatório: true
      validação: "1..32768 bytes"
    - campo: references
      tipo: "array[ContextReference]"
      obrigatório: true
      validação: "0..20; máximo agregado 4 MiB"
    - campo: context_budget_bytes
      tipo: "int"
      obrigatório: true
      validação: "1024..65536; default 16384"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: prepared_id
          tipo: "uuid"
        - campo: manifest
          tipo: "array[ContextReference]"
        - campo: included_bytes
          tipo: "int"
        - campo: manifest_sha256
          tipo: "sha256"
        - campo: expires_at_ms
          tipo: "int"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: composer.stage**

```yaml
interface:
  id: IF-0005-01-2
  tipo: function
  nome: "composer.stage"
  entrada:
    - campo: thread_id
      tipo: "uuid"
      obrigatório: true
      validação: "thread autorizada"
    - campo: filename
      tipo: "string"
      obrigatório: true
      validação: "1..255 bytes; basename sem path"
    - campo: mime
      tipo: "enum[text/plain,text/markdown,image/png,image/jpeg]"
      obrigatório: true
      validação: "lista fechada"
    - campo: content_base64
      tipo: "string"
      obrigatório: true
      validação: "base64 válido; <=5592408 bytes codificados; limite decodificado da fase prevalece"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: reference
          tipo: "ContextReference"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: composer.draft.save**

```yaml
interface:
  id: IF-0005-01-3
  tipo: function
  nome: "composer.draft.save"
  entrada:
    - campo: draft
      tipo: "ComposerDraft"
      obrigatório: true
      validação: "validar recursivamente; CAS por revision"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: draft_id
          tipo: "uuid"
        - campo: revision
          tipo: "int"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: composer.resolve**

```yaml
interface:
  id: IF-0005-01-4
  tipo: function
  nome: "composer.resolve"
  entrada:
    - campo: prepared_id
      tipo: "uuid"
      obrigatório: true
      validação: "principal/thread/environment associados à identidade delegada"
    - campo: manifest_sha256
      tipo: "sha256"
      obrigatório: true
      validação: "hash canônico esperado"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: context
          tipo: "PreparedContext"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: composer.pin**

```yaml
interface:
  id: IF-0005-01-5
  tipo: function
  nome: "composer.pin"
  entrada:
    - campo: prepared_id
      tipo: "uuid"
      obrigatório: true
      validação: "mesmo principal"
    - campo: command_id
      tipo: "uuid"
      obrigatório: true
      validação: "intenção estável que usará o contexto"
    - campo: retain
      tipo: "bool"
      obrigatório: true
      validação: "true cria referência idempotente; false libera"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: retained
          tipo: "bool"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: ContextReference
campos:
  - nome: reference_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: kind
    tipo: "enum[wiki,file,quote,image]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: relative_path
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: message_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: size_bytes
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: trust
    tipo: "enum[untrusted_content]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ComposerDraft
campos:
  - nome: draft_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: text
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: references
    tipo: "array[ContextReference]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ContextSegment
campos:
  - nome: reference_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: kind
    tipo: "enum[wiki,file,quote,image]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: mime
    tipo: "enum[text/plain,text/markdown,image/png,image/jpeg]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: content_base64
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: trust
    tipo: "enum[untrusted_content]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: PreparedContext
campos:
  - nome: prepared_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: principal_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: text
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: manifest
    tipo: "array[ContextReference]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: segments
    tipo: "array[ContextSegment]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: manifest_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

### Snapshot persistido desta fase

```yaml
tipo: FeatureSnapshot
campos:
  - nome: snapshot_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: as_of_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: next_cursor
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: drafts
    tipo: "array[ComposerDraft]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Texto do usuário e conteúdo de referência são segmentos distintos; referências sempre untrusted_content. AGENTS de projeto só entram pelo carregador de instruções autorizado, nunca pela ingestão de anexos.
2. Resolver realpath no environment dono do arquivo e revalidar antes da leitura; rejeitar symlink que escape e mudança de hash após preview.
3. Citação guarda texto exato, source ID, hash e proveniência. Se fonte some, manter citação salva e marcar fonte indisponível.
4. Não truncar pergunta atual. Orçamento insuficiente retorna ERR_BUDGET e lista referências removíveis; nenhum envio parcial.
5. Anexos precisam concluir staging antes de prepare; draft e stash sobrevivem reload, mas secret/token não entra no armazenamento do draft.
6. prepare persiste cópia imutável dos bytes autorizados por 86400000 ms; pin por command_id impede coleta enquanto fila/run existir. prepared_id não concede leitura: resolve exige credencial delegada com audience do serviço de contexto e principal/environment/thread corretos. Artefatos fixados mantêm bytes; mudança na fonte viva exige novo preview/prepare antes de novo envio, sem alterar retrospectivamente um contexto fixado.
7. manifest_sha256 usa SHA-256 de JSON canônico RFC 8785 de {environment_id,thread_id,principal_id,text,manifest}; hashes individuais cobrem bytes decodificados. content_base64 até 5592408 bytes; texto/pergunta e anexos obedecem aos limites específicos. Contexto máximo de 4 MiB decodificado; imagens chegam ao adapter como mídia somente se capability permitir, senão ERR_UNSUPPORTED.
8. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 20 referências; 4 MiB agregado em staging; 1 MiB por texto; 2 MiB por imagem; 65536 bytes de contexto máximo; 32768 bytes da pergunta; staging 30000 ms; stash retido por 24 h.

**Como realizar:**

1. Extrair composição para src/harness/composer e Services/Harness/Composer usando LocalAIContextBuilder/Picker somente via interfaces existentes.
2. Persistir referências por ID e hash em diretório privado de staging; copiar somente arquivos autorizados, sem persistir path absoluto em export por padrão.
3. Em módulo UI próprio, implementar chips, remover/reanexar, quote e budget; exercitar envio no host UI em E4; ligar ao shell de produção em E6.

### Dependências desta fase

```yaml
- id: DEP-0005-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0005-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0005-01-3
  tipo: componente_interno
  nome: "PocketWiki"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface composer.prepare exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-06 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 3.2 — Fase 02: Projeção e interface cliente

### O que é
Superfície web e macOS do domínio, consumindo o contrato confirmado sem executar efeitos diretamente na view. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Mostrar resultado, origem e estado de sincronização; manter seleção/draft e solicitar ações explícitas pela fachada.
- Expor navegação por teclado, foco e estados acessíveis em web 390/900/1440px e janela macOS compacta/regular.

**Fora do escopo deste componente:**
- Vídeo, áudio, editor rich text completo, executar instruções de anexos, permitir arquivos fora dos roots concedidos.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0005/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/composer/`, `Sources/PocketWikiMac/Views/Harness/Composer/`, `Tests/HarnessUI/composer/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: draft com 2 referências
quando: recarregar e enviar
então: draft e chips restaurados; mesma composição do manifesto

TESTE 02-02 [falha]
dado: upload falha
quando: tentar enviar
então: envio bloqueado com retry/remover, texto preservado

TESTE 02-03 [edge case]
dado: citação cuja origem foi removida
quando: abrir referência
então: texto salvo legível e fonte indisponível explícita

TESTE 02-04 [segurança]
dado: nome de arquivo com HTML
quando: listar anexo
então: nome escapado em preview e nenhuma execução

```

### Contratos de interface

```yaml
interface:
  id: IF-0005-02-1
  tipo: function
  nome: "composer.view.reduce"
  entrada:
    - campo: previous
      tipo: "ViewState"
      obrigatório: true
      validação: "estado inicial ou revision válida"
    - campo: snapshot
      tipo: "FeatureSnapshot"
      obrigatório: true
      validação: "projeção persistida paginada; mesmo snapshot_id/environment/thread; nunca resposta de comando"
    - campo: client_action
      tipo: "enum[open,refresh,submit,dismiss]"
      obrigatório: true
      validação: "evento local explícito"
    - campo: draft
      tipo: "string"
      obrigatório: true
      validação: "0..32768 bytes; conteúdo não confiável"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: view
          tipo: "ViewState"
        - campo: effect
          tipo: "enum[none,request,refresh]"
    falha:
      valores_possíveis:
        - code: ERR_INVALID
          quando: "entrada malformada, enum fora da lista ou limite excedido"
          ação: "400; rejeitar antes de I/O"
        - code: ERR_FORBIDDEN
          quando: "principal sem autorização para recurso/ação"
          ação: "403; não consultar nem modificar recurso"
        - code: ERR_TIMEOUT
          quando: "deadline da operação excedido"
          ação: "504; manter intenção/receipt e expor estado pending ou uncertain conforme efeito"
        - code: ERR_UNAVAILABLE
          quando: "dependência/store indisponível"
          ação: "503; preservar estado confirmado e permitir retry idempotente"
        - code: ERR_INCOMPATIBLE
          quando: "versão major ou schema obrigatório incompatível"
          ação: "426; não aplicar payload"
        - code: ERR_CONTEXT_STALE
          quando: "hash/revisão mudou"
          ação: "409; pedir novo preview"
        - code: ERR_BUDGET
          quando: "contexto não cabe"
          ação: "422; não enviar"
        - code: ERR_PATH_ESCAPE
          quando: "path sai do root"
          ação: "403; não abrir arquivo"
        - code: ERR_UNSUPPORTED
          quando: "MIME fora dos formatos aceitos para staging"
          ação: "422; manter draft e não enviar"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: ContextReference
campos:
  - nome: reference_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: kind
    tipo: "enum[wiki,file,quote,image]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: relative_path
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: message_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: size_bytes
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: trust
    tipo: "enum[untrusted_content]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ComposerDraft
campos:
  - nome: draft_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: text
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: references
    tipo: "array[ContextReference]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ContextSegment
campos:
  - nome: reference_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: kind
    tipo: "enum[wiki,file,quote,image]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: mime
    tipo: "enum[text/plain,text/markdown,image/png,image/jpeg]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: content_base64
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: trust
    tipo: "enum[untrusted_content]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: PreparedContext
campos:
  - nome: prepared_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: principal_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: text
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: manifest
    tipo: "array[ContextReference]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: segments
    tipo: "array[ContextSegment]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: manifest_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: FeatureSnapshot
campos:
  - nome: snapshot_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: as_of_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: next_cursor
    tipo: "string?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: drafts
    tipo: "array[ComposerDraft]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: ViewState
campos:
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: thread_id
    tipo: "uuid?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: status
    tipo: "enum[loading,ready,stale,error]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: draft
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: data
    tipo: "FeatureSnapshot?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: error
    tipo: "HarnessError?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

### Regras de comportamento

1. Texto do usuário e conteúdo de referência são segmentos distintos; referências sempre untrusted_content. AGENTS de projeto só entram pelo carregador de instruções autorizado, nunca pela ingestão de anexos.
2. Resolver realpath no environment dono do arquivo e revalidar antes da leitura; rejeitar symlink que escape e mudança de hash após preview.
3. Citação guarda texto exato, source ID, hash e proveniência. Se fonte some, manter citação salva e marcar fonte indisponível.
4. Não truncar pergunta atual. Orçamento insuficiente retorna ERR_BUDGET e lista referências removíveis; nenhum envio parcial.
5. Anexos precisam concluir staging antes de prepare; draft e stash sobrevivem reload, mas secret/token não entra no armazenamento do draft.
6. prepare persiste cópia imutável dos bytes autorizados por 86400000 ms; pin por command_id impede coleta enquanto fila/run existir. prepared_id não concede leitura: resolve exige credencial delegada com audience do serviço de contexto e principal/environment/thread corretos. Artefatos fixados mantêm bytes; mudança na fonte viva exige novo preview/prepare antes de novo envio, sem alterar retrospectivamente um contexto fixado.
7. manifest_sha256 usa SHA-256 de JSON canônico RFC 8785 de {environment_id,thread_id,principal_id,text,manifest}; hashes individuais cobrem bytes decodificados. content_base64 até 5592408 bytes; texto/pergunta e anexos obedecem aos limites específicos. Contexto máximo de 4 MiB decodificado; imagens chegam ao adapter como mídia somente se capability permitir, senão ERR_UNSUPPORTED.
8. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 20 referências; 4 MiB agregado em staging; 1 MiB por texto; 2 MiB por imagem; 65536 bytes de contexto máximo; 32768 bytes da pergunta; staging 30000 ms; stash retido por 24 h.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada composer.prepare; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0005-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0005-02-2
  tipo: componente_interno
  nome: "RFC-0005 fase 01"
  versão: "0.2.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0005-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface composer.view.reduce exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 02-01 a 02-04 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 4. Cenários de Falha Transversais

### Entrada inválida / malformada
Rejeitar antes de I/O com ERR_INVALID. Validar schema, byte limits, enum fechado e referências; manter última revisão e draft. Mensagem de erro redigida com correlation_id.

### Dependência indisponível ou lenta
Deadline explícito retorna ERR_TIMEOUT/ERR_UNAVAILABLE. UI indica pending/stale e oferece ação coerente. Se comando já foi aceito, consultar receipt; indisponibilidade não autoriza executar no cliente.

### Estado inconsistente entre fontes de dados
Autoridade é PocketWiki. Revisão confirmada vence cache; projeção divergente é reconstruída por snapshot/eventos e não pela seleção local. Corrupção é visível e não resulta em apagar histórico silenciosamente.

### Concorrência / race condition
Compare-and-swap por revision e idempotência por command_id/hash; escritor serializado no servidor. Resposta antiga de outra thread/environment é descartada sem afetar o draft atual.

### Exaustão de recurso
Aplicar limites da fase antes de alocar, interromper leitura no teto e responder ERR_INVALID/erro específico de limite. Disk-full ou descriptor indisponível retorna ERR_UNAVAILABLE, preservando arquivo anterior e receipt confirmado; não continuar efeito sem persistência.

### Segurança — entrada controlada por ator externo
Validar principal/environment/scope em toda interface. Paths canonicalizados com roots explícitos; textos, títulos, tool output e memória são conteúdo inerte. Não interpolar shell, HTML ou secrets em logs. Export e UI usam allowlist redigida.

### Timeout em operação normalmente rápida
Usar deadline numérico desta RFC com relógio injetável nos testes. Não inferir conclusão/cancelamento por tempo local; consultar estado durável e preservar intenção incerta até reconciliação.

## 5. Decisões e Restrições

| ID | Decisão | Motivo | Reversível |
| --- | --- | --- | --- |
| DEC-01 | Estado de evolução Draft, completude COMPLETO | revisar proposta sem confundir com implementação | sim |
| DEC-02 | Autoridade de domínio em PocketWiki | preservar RFC-0001 e limites dos add-ons | não |
| DEC-03 | Capability antes de habilitar ação | providers/ambientes têm garantias diferentes | não |
| DEC-04 | Implementação própria, referência t3code fixada por SHA | rastrear origem sem depender de main móvel | sim |
| DEC-05 | Etapa só avança com revisão e E2E integrado | validar a união das worktrees e os contratos | não |
| DEC-06 | Limites acima são proposta explícita do PocketWiki | manter comportamento testável e revisável | sim |

**Alternativas descartadas:**
- Copiar aplicação t3code inteira: descartada porque PocketWiki já tem UI Swift, servidor Node, PocketKernel e MiddlewareAuth com domínios próprios.
- Executar efeito direto no cliente: descartada por quebrar autoridade do environment e idempotência.
- Testar apenas reducers com eventos pré-normalizados: descartada porque não valida adapter, transporte e persistência reais.

Evolução após revisão: atualizar este mesmo documento para 0.3.0 com changelog de decisão, gerar os 2 contratos na ordem do mapa, implementar lanes do plano e só então propor estado Accepted. Mudança incompatível de wire exige protocol major novo; status COMPLETO não permite pular gate.
