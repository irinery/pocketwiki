# RFC — Ambientes remotos, pareamento e reconexão

**Projeto:** PocketWiki / New Harness. (RFC-0010)
**Data:** 2026-11-01
**Issue:** [#31](https://github.com/irinery/pocketwiki/issues/31)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

> Tipo transversal `HarnessError = {code:string (enum da interface), message:string (0..1024 bytes redigidos), correlation_id:uuid, retryable:bool}`. Em wire, bool = boolean JSON. Identidade e scopes são obtidos do transporte autenticado, nunca de um campo user_id escolhido pelo cliente.

## 1. Visão Geral

### 1.1 Problema
Há endpoint remoto efetivo e contratos de integração, mas faltam identidade persistente de environment, conexão por escopo e recuperação de stream sem usar estado da máquina cliente.

### 1.2 Solução
Parear ambientes com identidade e scopes próprios e manter um supervisor de conexão por environment.

O recorte desta RFC é: Conexão direta HTTPS/LAN ou tailnet via URL configurada, challenge de pareamento de uso único, revogação, cache offline de leitura e cursor de retomada.

### 1.3 Fora de escopo
Construir relay equivalente ao T3 Connect, provisionar Tailscale, confiar em mDNS, executar fallback local quando host remoto falha.

**Origem e adaptação:** comportamento observado nos documentos abaixo da revisão `5732bbee397f0a2b0e61d0c2e432f01dca6df3dc`. A implementação proposta é própria e mantém domínio em PocketWiki + PocketKernel + MiddlewareAuth. Limites e políticas deste draft pertencem ao PocketWiki e não são transcrição dos defaults do t3code.

- [docs/user/remote-access.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/user/remote-access.md)
- [docs/internals/connection-runtime.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/connection-runtime.md)
- [docs/internals/environment-auth.md](https://github.com/pingdotgg/t3code/blob/5732bbee397f0a2b0e61d0c2e432f01dca6df3dc/docs/internals/environment-auth.md)

## 2. Mapa de Fases

| Fase | Arquivo | Nome do componente | Depende de | Paralelizável com |
| --- | --- | --- | --- | --- |
| 01 | 01_environments_dominio.md | Contrato e serviço de domínio | RFC-0002/01/02, RFC-0006/01 | lanes backend da mesma etapa do plano, sem dependência entre elas |
| 02 | 02_environments_cliente.md | Transporte/projeção e superfície cliente | 01 | lanes cliente da mesma etapa do plano, com diretórios exclusivos |

Arquivos de contrato serão gerados em `docs/technical-contract/new-harness/environments/`; este draft entrega uma RFC inteira, não contratos parciais. A agenda global e os gates estão em `plano-worktrees.md`; cada fase só começa após dependências integradas no SHA base.

### Convenções globais
- PocketWiki + PocketKernel + MiddlewareAuth é autoridade deste domínio; PocketWiki não lê store privado de integração externa.
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
Parear ambientes com identidade e scopes próprios e manter um supervisor de conexão por environment. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Conexão direta HTTPS/LAN ou tailnet via URL configurada, challenge de pareamento de uso único, revogação, cache offline de leitura e cursor de retomada.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Construir relay equivalente ao T3 Connect, provisionar Tailscale, confiar em mDNS, executar fallback local quando host remoto falha.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02, RFC-0006/01.

**Posse de arquivos:** MiddlewareAuth: `internal/harness-sessions/` (exclusivo desta lane E3). PocketWiki: `src/harness/environments/`, `Sources/PocketWikiMac/Services/Harness/Environments/`, `Tests/Harness/environments/`. PocketKernel (outro repo): novo módulo lógico `harness/environments` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: challenge válido com fingerprint confirmado
quando: parear e chamar runtime.dispatch no agregado remoto de teste já integrado E1
então: environment e scopes persistidos; execução ocorre somente no servidor

TESTE 01-02 [falha]
dado: token revogado durante stream
quando: submeter novo comando
então: ERR_FORBIDDEN e stream fechado; sem fallback local

TESTE 01-03 [edge case]
dado: 2 assinantes do cliente base abrem mesmo environment e rede oscila
quando: reconectar
então: 1 supervisor/stream e projeção monotônica

TESTE 01-04 [segurança]
dado: challenge reutilizado, Origin hostil ou endpoint com userinfo
quando: parear
então: ERR_PAIRING/ERR_INVALID e nenhuma credencial persistida

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

TESTE 01-06 [integração]
dado: cliente limpo e MiddlewareAuth real com identidade de teste
quando: parear, chamar API, renovar e revogar conexão
então: primeiro bearer funciona; refresh anterior e access token revogado são recusados; nenhum secret no ledger

```

### Contratos de interface

```yaml
interface:
  id: IF-0010-01-1
  tipo: function
  nome: "environments.pair"
  entrada:
    - campo: endpoint
      tipo: "string"
      obrigatório: true
      validação: "URL HTTPS sem credenciais/query; HTTP só loopback"
    - campo: challenge_id
      tipo: "uuid"
      obrigatório: true
      validação: "emitido pelo host autenticado"
    - campo: challenge_secret
      tipo: "string"
      obrigatório: true
      validação: "32 bytes aleatórios codificados base64url"
    - campo: server_fingerprint
      tipo: "sha256"
      obrigatório: true
      validação: "confirmado na tela dos 2 dispositivos"
    - campo: requested_scopes
      tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
      obrigatório: true
      validação: "subset da concessão do host"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: environment_id
          tipo: "uuid"
        - campo: connection_id
          tipo: "uuid"
        - campo: granted_scopes
          tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
        - campo: grant
          tipo: "SessionGrant"
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
        - code: ERR_PAIRING
          quando: "challenge inválido/expirado/usado"
          ação: "403; não emitir credencial"
        - code: ERR_IDENTITY_CHANGED
          quando: "fingerprint diverge"
          ação: "409; limpar sessão de transporte e exigir novo vínculo"
        - code: ERR_OFFLINE
          quando: "ambiente desconectado"
          ação: "503; preservar draft"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: environments.challenge**

```yaml
interface:
  id: IF-0010-01-2
  tipo: function
  nome: "environments.challenge"
  entrada:
    - campo: requested_scopes
      tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
      obrigatório: true
      validação: "1..9 únicos; host autenticado"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: challenge_id
          tipo: "uuid"
        - campo: challenge_secret
          tipo: "string"
        - campo: server_fingerprint
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
        - code: ERR_PAIRING
          quando: "challenge inválido/expirado/usado"
          ação: "403; não emitir credencial"
        - code: ERR_IDENTITY_CHANGED
          quando: "fingerprint diverge"
          ação: "409; limpar sessão de transporte e exigir novo vínculo"
        - code: ERR_OFFLINE
          quando: "ambiente desconectado"
          ação: "503; preservar draft"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: environments.revoke**

```yaml
interface:
  id: IF-0010-01-3
  tipo: function
  nome: "environments.revoke"
  entrada:
    - campo: connection_id
      tipo: "uuid"
      obrigatório: true
      validação: "host/admin da conexão autorizada"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: revoked
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
        - code: ERR_PAIRING
          quando: "challenge inválido/expirado/usado"
          ação: "403; não emitir credencial"
        - code: ERR_IDENTITY_CHANGED
          quando: "fingerprint diverge"
          ação: "409; limpar sessão de transporte e exigir novo vínculo"
        - code: ERR_OFFLINE
          quando: "ambiente desconectado"
          ação: "503; preservar draft"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

**Interface complementar: environments.refresh**

```yaml
interface:
  id: IF-0010-01-4
  tipo: function
  nome: "environments.refresh"
  entrada:
    - campo: session_id
      tipo: "uuid"
      obrigatório: true
      validação: "sessão emitida para este dispositivo"
    - campo: refresh_token
      tipo: "string"
      obrigatório: true
      validação: "32 bytes base64url; nunca em URL/log"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: grant
          tipo: "SessionGrant"
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
        - code: ERR_PAIRING
          quando: "challenge inválido/expirado/usado"
          ação: "403; não emitir credencial"
        - code: ERR_IDENTITY_CHANGED
          quando: "fingerprint diverge"
          ação: "409; limpar sessão de transporte e exigir novo vínculo"
        - code: ERR_OFFLINE
          quando: "ambiente desconectado"
          ação: "503; preservar draft"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: EnvironmentConnection
campos:
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: endpoint
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: server_fingerprint
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: state
    tipo: "enum[offline,connecting,ready,stale,auth_required,incompatible]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: last_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: connection_id
    tipo: "uuid"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
  - nome: granted_scopes
    tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
```

```yaml
tipo: PairingChallenge
campos:
  - nome: challenge_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: secret_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: consumed
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: SessionGrant
campos:
  - nome: session_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: principal_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: access_token
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: refresh_token
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: token_type
    tipo: "enum[Bearer]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: refresh_expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: audience
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: scopes
    tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
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
  - nome: connections
    tipo: "array[EnvironmentConnection]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Identity do environment é fixa e inclui fingerprint; mudar endpoint exige revalidar identidade. Nenhum filesystem/provider/credencial do cliente substitui o remoto.
2. Supervisor único por environment. Reconexão backoff 1000,2000,4000,8000,16000,30000 ms com jitter ±20%; reset após 30000 ms ready. Auth falhou: parar até novo login.
3. Transporte conectado não significa projeção atualizada. Ready exige capabilities + snapshot; snapshot antigo não sobrescreve seq maior.
4. Pareamento TTL 300000 ms, uso único, no máximo 5 falhas por challenge. Revogação fecha stream e impede novos comandos. Challenge não aparece em logs/URL.
5. Offline conserva leitura com indicador stale. Mutação offline fica draft local; reenviar usa command_id original só após usuário confirmar e reconciliar receipt.
6. pair e refresh são endpoints de bootstrap diretos, fora do dispatcher autenticado genérico. pair autentica challenge_secret de uso único e fingerprint confirmado; refresh autentica o refresh token. Respostas sensíveis TLS/no-store entregam SessionGrant somente ao dispositivo solicitante; grant jamais entra em receipt, snapshot, evento ou export. connection_id sozinho não autoriza chamadas.
7. MiddlewareAuth real emite bearer opaco de 32 bytes aleatórios, TTL 900000 ms e refresh rotativo de 32 bytes, TTL absoluto 2592000000 ms. Validar por introspecção autenticada server-to-server (sem cache positivo) em cada mutação; stream revalida a cada 1000 ms e em eventos de revogação. Refresh consumido não pode repetir; se perder resposta, novo pareamento. Revogação por connection_id invalida família inteira antes de responder. Contrato detalhado de emissão/introspecção consta em contratos-integracao-v0.2.md.
8. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 16 environments por cliente; TTL challenge 300000 ms; 5 falhas por challenge; probe 15000 ms; backoff máximo 30000 ms; snapshot 4 MiB; 0 mutação automática offline.

**Como realizar:**

1. Usar registro e confiança da RFC-0001 como base; separar discovery de pairing. MiddlewareAuth emite credencial de sessão scoped, não token de provider.
2. Criar supervisor multiplataforma por contrato: JS no web e Swift no Mac com mesmos fixtures; não é compartilhamento de código Swift/JS.
3. Keychain no Mac; sessão web em memória/sessionStorage com política de origem e renovação. Não usar token da memória como autorização de execução.

### Dependências desta fase

```yaml
- id: DEP-0010-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0010-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0010-01-3
  tipo: componente_interno
  nome: "RFC-0006 fase 01"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0010-01-4
  tipo: componente_interno
  nome: "PocketWiki + PocketKernel + MiddlewareAuth"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface environments.pair exercitáveis sem integração com shell compartilhado
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
- Construir relay equivalente ao T3 Connect, provisionar Tailscale, confiar em mDNS, executar fallback local quando host remoto falha.
- Executar subprocessos, ler filesystem local como substituto do servidor, acessar credencial de provider ou alterar regra de negócio.

**Dependências repetidas:** RFC-0010/01 + NH-00 + NH-TEST.

**Posse de arquivos:** `src/harness-ui/environments/`, `Sources/PocketWikiMac/Views/Harness/Environments/`, `Tests/HarnessUI/environments/`.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 02-01 [caminho feliz]
dado: cache offline e draft
quando: reabrir IA sem rede
então: histórico stale legível, envio bloqueado e draft intacto

TESTE 02-02 [falha]
dado: conexão abre mas snapshot falha
quando: observar indicador
então: stale/erro de sync; não ready falso

TESTE 02-03 [edge case]
dado: endpoint muda para outro fingerprint
quando: reconectar
então: exige novo pareamento sem transportar token antigo

TESTE 02-04 [segurança]
dado: notificação com texto hostil
quando: abrir evento remoto
então: conteúdo inerte e navegação vinculada ao environment original

```

### Contratos de interface

```yaml
interface:
  id: IF-0010-02-1
  tipo: function
  nome: "environments.view.reduce"
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
        - code: ERR_PAIRING
          quando: "challenge inválido/expirado/usado"
          ação: "403; não emitir credencial"
        - code: ERR_IDENTITY_CHANGED
          quando: "fingerprint diverge"
          ação: "409; limpar sessão de transporte e exigir novo vínculo"
        - code: ERR_OFFLINE
          quando: "ambiente desconectado"
          ação: "503; preservar draft"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: EnvironmentConnection
campos:
  - nome: environment_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: endpoint
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: server_fingerprint
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: state
    tipo: "enum[offline,connecting,ready,stale,auth_required,incompatible]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: last_seq
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: connection_id
    tipo: "uuid"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
  - nome: granted_scopes
    tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
```

```yaml
tipo: PairingChallenge
campos:
  - nome: challenge_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: secret_sha256
    tipo: "sha256"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: consumed
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
```

```yaml
tipo: SessionGrant
campos:
  - nome: session_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: principal_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: access_token
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: refresh_token
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: token_type
    tipo: "enum[Bearer]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: refresh_expires_at_ms
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: audience
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: scopes
    tipo: "array[enum[read,submit,approve,execute,context.read,memory.personal.read,memory.write,scm.write,scm.merge]]"
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
  - nome: connections
    tipo: "array[EnvironmentConnection]"
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

1. Identity do environment é fixa e inclui fingerprint; mudar endpoint exige revalidar identidade. Nenhum filesystem/provider/credencial do cliente substitui o remoto.
2. Supervisor único por environment. Reconexão backoff 1000,2000,4000,8000,16000,30000 ms com jitter ±20%; reset após 30000 ms ready. Auth falhou: parar até novo login.
3. Transporte conectado não significa projeção atualizada. Ready exige capabilities + snapshot; snapshot antigo não sobrescreve seq maior.
4. Pareamento TTL 300000 ms, uso único, no máximo 5 falhas por challenge. Revogação fecha stream e impede novos comandos. Challenge não aparece em logs/URL.
5. Offline conserva leitura com indicador stale. Mutação offline fica draft local; reenviar usa command_id original só após usuário confirmar e reconciliar receipt.
6. pair e refresh são endpoints de bootstrap diretos, fora do dispatcher autenticado genérico. pair autentica challenge_secret de uso único e fingerprint confirmado; refresh autentica o refresh token. Respostas sensíveis TLS/no-store entregam SessionGrant somente ao dispositivo solicitante; grant jamais entra em receipt, snapshot, evento ou export. connection_id sozinho não autoriza chamadas.
7. MiddlewareAuth real emite bearer opaco de 32 bytes aleatórios, TTL 900000 ms e refresh rotativo de 32 bytes, TTL absoluto 2592000000 ms. Validar por introspecção autenticada server-to-server (sem cache positivo) em cada mutação; stream revalida a cada 1000 ms e em eventos de revogação. Refresh consumido não pode repetir; se perder resposta, novo pareamento. Revogação por connection_id invalida família inteira antes de responder. Contrato detalhado de emissão/introspecção consta em contratos-integracao-v0.2.md.
8. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 16 environments por cliente; TTL challenge 300000 ms; 5 falhas por challenge; probe 15000 ms; backoff máximo 30000 ms; snapshot 4 MiB; 0 mutação automática offline.

No cliente: renderizar 100 itens por página; draft 32768 bytes; erro 1024 bytes; request HTTP 30000 ms; 0 retries cegos de mutação e 0 fallback para outra identidade. Deadlines específicos da fase 01 prevalecem. Timeout visual não cancela trabalho servidor por inferência.

**Como realizar:**

1. Consumir somente a fachada congelada environments.pair; renderizar os campos da fase 01 em módulo independente, sem reabrir backend.
2. Implementar estado loading/ready/stale/error e draft por thread/environment. Acionar request por callback tipado; efeitos e autorização pertencem ao servidor.
3. Adicionar IDs de acessibilidade estáveis e cenário browser/macOS que abra o módulo através do slot de teste de E0. A ligação nos arquivos compartilhados é exclusiva do gate E6.

### Dependências desta fase

```yaml
- id: DEP-0010-02-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0010-02-2
  tipo: componente_interno
  nome: "RFC-0010 fase 01"
  versão: "0.2.0"
  papel: "serviço e projeção tipados"
  fallback: "cache de leitura stale e ação desabilitada"
  obrigatória: true
- id: DEP-0010-02-3
  tipo: biblioteca
  nome: "SwiftUI + módulos ES nativos"
  versão: "Swift 6 / package-lock.json do PocketWiki"
  papel: "renderização e transporte por fachada"
  fallback: "não substituir por framework novo nesta lane"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface environments.view.reduce exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 02-01 a 02-04 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

## 4. Cenários de Falha Transversais

### Entrada inválida / malformada
Rejeitar antes de I/O com ERR_INVALID. Validar schema, byte limits, enum fechado e referências; manter última revisão e draft. Mensagem de erro redigida com correlation_id.

### Dependência indisponível ou lenta
Deadline explícito retorna ERR_TIMEOUT/ERR_UNAVAILABLE. UI indica pending/stale e oferece ação coerente. Se comando já foi aceito, consultar receipt; indisponibilidade não autoriza executar no cliente.

### Estado inconsistente entre fontes de dados
Autoridade é PocketWiki + PocketKernel + MiddlewareAuth. Revisão confirmada vence cache; projeção divergente é reconstruída por snapshot/eventos e não pela seleção local. Corrupção é visível e não resulta em apagar histórico silenciosamente.

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
| DEC-02 | Autoridade de domínio em PocketWiki + PocketKernel + MiddlewareAuth | preservar RFC-0001 e limites dos add-ons | não |
| DEC-03 | Capability antes de habilitar ação | providers/ambientes têm garantias diferentes | não |
| DEC-04 | Implementação própria, referência t3code fixada por SHA | rastrear origem sem depender de main móvel | sim |
| DEC-05 | Etapa só avança com revisão e E2E integrado | validar a união das worktrees e os contratos | não |
| DEC-06 | Limites acima são proposta explícita do PocketWiki | manter comportamento testável e revisável | sim |

**Alternativas descartadas:**
- Copiar aplicação t3code inteira: descartada porque PocketWiki já tem UI Swift, servidor Node, PocketKernel e MiddlewareAuth com domínios próprios.
- Executar efeito direto no cliente: descartada por quebrar autoridade do environment e idempotência.
- Testar apenas reducers com eventos pré-normalizados: descartada porque não valida adapter, transporte e persistência reais.

Evolução após revisão: atualizar este mesmo documento para 0.3.0 com changelog de decisão, gerar os 2 contratos na ordem do mapa, implementar lanes do plano e só então propor estado Accepted. Mudança incompatível de wire exige protocol major novo; status COMPLETO não permite pular gate.
