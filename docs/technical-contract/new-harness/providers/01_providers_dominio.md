# RFC — Adapters, capabilities, modelos e contas

**Projeto:** PocketWiki / New Harness. (RFC-0003)
**Data:** 2026-11-01
**Issue:** [#24](https://github.com/irinery/pocketwiki/issues/24)
**Estado de evolução:** Draft
**Versão da RFC:** 0.2.0
**Status:** COMPLETO
**Fases:** 2 arquivos a gerar
**Gerado por:** Codex, sessão New Harness

> COMPLETO significa especificação do draft preenchida; não significa aprovação, implementação ou estabilidade pública. Todos os endpoints harness.v1, módulos e limites abaixo são propostas. O endpoint atual POST /v1/kernel permanece compatível. Primitivos deste cabeçalho: uuid = UUID RFC 4122 canônico minúsculo; sha1 = 40 hex; sha256 = 64 hex; int = inteiro JSON seguro 0..9007199254740991 salvo exit_code, que aceita -255..255; string = UTF-8; `?` = opcional/ausente, nunca null implícito; array[T] = lista homogênea; enum[...] = lista fechada. Timestamps são int em ms UTC. Campos desconhecidos de comando são rejeitados; campos opcionais novos em resposta exigem minor negociado. Tipos são repetidos por fase. Regras de transporte, paginação, sessão e canonicalização são normativas em contratos-integracao-v0.2.md, que integra o cabeçalho desta RFC.

## 3.1 — Fase 01: Domínio e persistência

### O que é
Separar providers de inferência e agents de execução com capabilities verificadas e binding imutável por run. A entrega desta fase usa somente o escopo abaixo e não modifica módulos de outra lane.

**Responsabilidades:**
- Adapter OpenAI/LM Studio compatível com o fluxo atual; adapter Codex CLI como primeiro agent opcional; catálogo, conta, versão, reasoning e restrições declaradas. Claude/Cursor/OpenCode ficam extensões futuras do mesmo contrato.
- Persistir revisão/receipt e expor resultado tipado com erros observáveis.

**Fora do escopo deste componente:**
- Prometer suporte funcional a todos os providers do t3code; ler tokens de CLI na UI; inventar reasoning ou janela de contexto; trocar conta silenciosamente.
- Editar views existentes, rotas globais e scripts de CI nesta lane.

**Dependências repetidas:** RFC-0002/01/02.

**Posse de arquivos:** PocketWiki: `src/harness/providers/`, `Sources/PocketWikiMac/Services/Harness/Providers/`, `Tests/Harness/providers/`. PocketKernel (outro repo): novo módulo lógico `harness/providers` e seus testes; adapter para store existente, sem substituir serviços privados de outro domínio.  Os paths são destinos propostos; arquivos compartilhados de serviços só mudam pelo integrador da etapa; shell de produção pelo integrador E6. UI de teste usa registro por slot, sem tocar o shell de produção.

### Testes obrigatórios

Escrever os cenários antes da implementação. Fixtures substituem apenas fronteiras de processo/rede/clock/IDs; store, policy, normalizador e projeção reais.

```
TESTE 01-01 [caminho feliz]
dado: catálogo com inference e agent autenticados
quando: selecionar modelo compatível e executar chamada pelo driver real do adapter, sem threads
então: binding e capabilities correspondem à conta selecionada

TESTE 01-02 [falha]
dado: CLI ausente ou versão não validada
quando: selecionar agent
então: ERR_PROVIDER_UNAVAILABLE e chat inference continua operante

TESTE 01-03 [edge case]
dado: troca de conta durante chamada direta do adapter
quando: concluir chamada e enviar próximo prompt pelo driver do adapter
então: chamada antiga usa binding antigo; nova usa novo binding

TESTE 01-04 [segurança]
dado: provider_id com shell metacharacters e account_ref estrangeiro
quando: selecionar provider
então: ERR_INVALID ou ERR_FORBIDDEN; zero subprocesso indevido

TESTE 01-05 [integração]
dado: projeção válida com mais entidades que page_size e cache cliente apagado
quando: ler ao menos 2 páginas do mesmo snapshot enquanto ocorre mutação concorrente
então: snapshot consistente na boundary e evento posterior aplicado 1 vez, sem duplicação

```

### Contratos de interface

```yaml
interface:
  id: IF-0003-01-1
  tipo: function
  nome: "providers.select"
  entrada:
    - campo: provider_id
      tipo: "string"
      obrigatório: true
      validação: "1..120 bytes; ID do catálogo"
    - campo: account_ref
      tipo: "string"
      obrigatório: true
      validação: "1..120 bytes; referência opaca, nunca secret"
    - campo: model_id
      tipo: "string"
      obrigatório: true
      validação: "1..120 bytes; catálogo atual"
    - campo: reasoning
      tipo: "string?"
      obrigatório: false
      validação: "ID publicado pelo modelo; ausente usa default"
    - campo: mode
      tipo: "enum[inference,agent]"
      obrigatório: true
      validação: "compatível com provider"
    - campo: catalog_revision
      tipo: "int"
      obrigatório: true
      validação: ">= 1; deve coincidir"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: binding_id
          tipo: "uuid"
        - campo: capabilities
          tipo: "ProviderCapabilities"
        - campo: catalog_revision
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
        - code: ERR_PROVIDER_UNAVAILABLE
          quando: "adapter/binário/login não utilizável"
          ação: "503; manter seleção anterior"
        - code: ERR_CATALOG_STALE
          quando: "revisão de catálogo diverge"
          ação: "409; solicitar refresh"
        - code: ERR_UNSUPPORTED
          quando: "capability não publicada"
          ação: "422; impedir ação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Para operações da classe mutation, o envelope de transporte é `HarnessCommand {protocol_major:int=1, command_id:uuid, environment_id:uuid, expected_revision:int, operation:string, input:<entrada tipada acima>}`. `operation` é o nome canônico desta interface; input não aceita campos extras. Erro segue HarnessError do cabeçalho; resposta de sucesso contém exatamente os campos de saída declarados. Leituras usam a rota query e operações bootstrap usam os endpoints diretos de R4, sem receipt; interface de view é local. O registry não encaminha bootstrap pelo ledger.

**Interface complementar: providers.catalog**

```yaml
interface:
  id: IF-0003-01-2
  tipo: function
  nome: "providers.catalog"
  entrada:
    - campo: project_id
      tipo: "uuid?"
      obrigatório: false
      validação: "projeto legível"
  saída:
    sucesso:
      tipo: Result
      campos:
        - campo: revision
          tipo: "int"
        - campo: bindings
          tipo: "array[ProviderBinding]"
        - campo: capabilities
          tipo: "array[ProviderCapabilities]"
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
        - code: ERR_PROVIDER_UNAVAILABLE
          quando: "adapter/binário/login não utilizável"
          ação: "503; manter seleção anterior"
        - code: ERR_CATALOG_STALE
          quando: "revisão de catálogo diverge"
          ação: "409; solicitar refresh"
        - code: ERR_UNSUPPORTED
          quando: "capability não publicada"
          ação: "422; impedir ação"
  comportamento_em_falha:
    - condição: "qualquer erro da lista fechada acima"
      ação: "não assumir sucesso; preservar draft e última revisão confirmada; exibir code com correlation_id; mutação sem confirmação exige consulta do receipt antes de retry"
      observável: "estado de erro/pending explícito; nenhuma mudança silenciosa de provider, conta, root ou ambiente"
```

Interfaces complementares são operações do mesmo registro tipado, usam o envelope e a lista fechada de erros desta fase. Leitura não cria efeito. Mutação passa por policy, CAS e receipt; todas validam os mesmos limites antes de I/O.

### Estruturas de dados

```yaml
tipo: ProviderCapabilities
campos:
  - nome: version
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: stream_text
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: steer
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: interrupt
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: rollback
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: native_fork
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: tools
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: questions
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: plans
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: resume
    tipo: "bool"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: context_bytes
    tipo: "int?"
    obrigatório: false
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: capability_id
    tipo: "uuid"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
```

```yaml
tipo: ProviderBinding
campos:
  - nome: binding_id
    tipo: "uuid"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: provider_id
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: account_ref
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: model_id
    tipo: "string"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: mode
    tipo: "enum[inference,agent]"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: catalog_revision
    tipo: "int"
    obrigatório: true
    default: nenhum
    limite: "primitivos conforme cabeçalho; strings gerais 4096 bytes, arrays 100 itens; limites de campos e paginação prevalecem"
  - nome: capability_id
    tipo: "uuid"
    obrigatório: true
    default: "ausente"
    limite: "conforme contratos-integracao-v0.2.md"
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
    tipo: "string"
    obrigatório: false
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: bindings
    tipo: "array[ProviderBinding]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
  - nome: capabilities
    tipo: "array[ProviderCapabilities]"
    obrigatório: true
    default: nenhum
    limite: "conforme regras desta fase; strings gerais 4096 bytes e arrays gerais 100 itens, salvo limite específico"
```

### Regras de comportamento

1. Capabilities default false até handshake do adapter; inferência não anuncia terminal nem edição. Falha de resume retorna erro explícito, sem fingir continuidade nativa.
2. Binding é congelado ao iniciar run. Troca solicitada durante run afeta o próximo run; preserva a conta anterior no histórico.
3. Catálogo de modelos e contas é do environment e do MiddlewareAuth. Credential handle é opaco; agent autenticado no host usa o login nativo, sem exportar seu token.
4. Adapter lança executável configurado como argv; handshake registra versão. Modelo/custom reasoning desconhecido é rejeitado antes de criar efeito.
5. Protocolo de CLI é fixado por versão no lock de compatibilidade; E0 registra uma versão real obtida de --version e transcrição sanitizada. CLI sem versão validada fica unavailable.
6. FeatureSnapshot é projeção persistida de leitura, nunca resultado de comando. Paginação usa snapshot_id/as_of_seq fixos, cursor opaco vinculado à identidade e TTL 600000 ms, 100 entidades por página no total e 4 MiB por página; ordenação por coleção e ID. Cursor novo ausente na última página. Cliente monta todas as páginas antes da troca atômica de estado e aplica somente eventos seq > as_of_seq; cursor expirado reinicia snapshot sem perder draft local. Entidade >4 MiB é rejeitada na escrita, sem truncamento silencioso. Arrays vazios e ausência de dados são estados iniciais válidos, sem IDs fictícios.

| Autorização/versão | Estado confirmado | Resultado | Ação |
| --- | --- | --- | --- |
| negada ou incompatível | qualquer | erro fechado | impedir efeito e preservar estado confirmado |
| válida | dependência indisponível | pending/stale ou erro | expor código; consultar receipt antes de retry |
| válida | revisão mudou | conflito | reconciliar snapshot sem sobrescrever edição local |
| válida | revisão atual | sucesso tipado | executar somente a ação explícita e aplicar revisão monotônica |

**Limites numéricos explícitos:** 120 bytes por identificador; 100 modelos por provider; 32 contas por environment; handshake 10000 ms; listagem 5000 ms; 0 fallback automático para outra conta.

**Como realizar:**

1. Implementar registry e normalizadores no PocketKernel; manter integração inferência através do bridge atual e referência de perfil MiddlewareAuth.
2. Fixar transcrições brutas por protocolo/versão e validar evento de início, delta, conclusão, erro e interrupt no adapter real.
3. Criar módulos UI de seleção separados das Views atuais. O integrador conecta-os a LocalAISidePanels e ao cockpit depois do gate.

### Dependências desta fase

```yaml
- id: DEP-0003-01-1
  tipo: componente_interno
  nome: "NH-00/contratos harness.v1"
  versão: "1.0.0"
  papel: "tipos e fixtures congelados"
  fallback: "bloquear merge até gate E0"
  obrigatória: true
- id: DEP-0003-01-2
  tipo: componente_interno
  nome: "RFC-0002 fases 01 e 02"
  versão: "0.2.0"
  papel: "interface liberada em gate anterior"
  fallback: "ERR_UNAVAILABLE; não implementar cópia nesta worktree"
  obrigatória: true
- id: DEP-0003-01-3
  tipo: componente_interno
  nome: "PocketKernel + MiddlewareAuth"
  versão: "harness.v1 proposto"
  papel: "autoridade do domínio"
  fallback: "capability ausente: modo legado ou recurso indisponível; sem execução substituta"
  obrigatória: true
```

### Entrega mínima desta fase

- [ ] módulo e interface providers.select exercitáveis sem integração com shell compartilhado
- [ ] fixtures reais sanitizadas, falhas e relatório de execução com SHA base e final
- [ ] todos os testes 01-01 a 01-05 passando
- [ ] nenhum arquivo fora da posse da lane alterado; mudanças compartilhadas entregues como instrução ao integrador

