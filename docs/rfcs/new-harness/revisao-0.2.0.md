# Segunda revisão — New Harness 0.2.0

2026-11-01 · PR #45 · revisão documental sobre a proposta; sem implementação das etapas.

Resultado: os sete apontamentos foram tratados. A proposta pode iniciar E0, na ordem NH-00 → NH-TEST. Isso não aprova o gate E0, não libera E1 e não habilita harness.v1 em produção. Todas as issues de implementação e gates permanecem abertas. Os drafts continuam Draft 0.2.0; COMPLETO descreve a especificação proposta.

## Apontamentos e correções

| Achado | Correção verificável | Evidência exigida na implementação |
| --- | --- | --- |
| R1 — snapshot era resposta de comando | FeatureSnapshot próprio em cada módulo, coleções persistidas, chaves estáveis, paginação consistente e boundary; receipt/result separados | SERVICE de cada RFC: apagar cache, ler múltiplas páginas durante mutação, aplicar evento posterior uma vez; terminal recupera bytes por terminal.read |
| R2 — contexto preparado não chegava ao provider | prepared_id/hash no enqueue; prepare/pin/resolve autenticados, bytes imutáveis, TTL e compensação de crash; erro segura fila | composer/01 prova retenção/isolamento em E2; CONTEXT-CHAIN em E3 confere bytes, roles, exclusões e frames outbound do adapter |
| R3 — aprovação não descrevia ação | PermissionAction discriminada, argv/cwd/patch/pergunta/ForgePreview completos; hash canônico, portas request/consume e concessão vinculada ao effect_id | permissions/01: payload alterado negado, concorrência e replay do mesmo efeito; UI-0006 exibe ação real; Git/PR usa mesma concessão |
| R4 — pairing não entregava sessão utilizável | grant explícito, endpoints bootstrap, audience/scopes, issue/introspect/rotate/revoke, armazenamento e revogação definidos | AUTH-REAL E3: cliente limpo obtém grant, usa API, renova, revoga; audience errada, refresh reutilizado/expirado e indisponibilidade recusados |
| R5 — worktrees consumiam implementações irmãs | threads.history E3; MCP/handoff E4; dependências threads→composer e checkpoints→providers explícitas; adapters de E2 e sessões de E3 têm donos distintos | grafo do manifest sem arestas entre lanes da mesma etapa; integração por etapa registra serviços; HISTORY-CHAIN E4 usa histórico completo sem cache |
| R6 — gates exigiam features futuras | E0 corpus/legado; E1 runtime com I/O mínimo e cliente base; E2 serviços; E3 contexto/auth; E4/E5 módulos visuais; E6 shell | matriz declara dependências e superfícies por caso; nenhum caso exige fase futura; UI do runtime/02 é entregue serialmente em E1 |
| R7 — auth real/SHA não eram obrigatórios | testes AUTH-REAL/AUTH-SHELL, emissor e verificador reais, relatório com SHA de MiddlewareAuth; agregador exige todos os pares cenário/superfície | recusar relatório ausente, skip, conflito, SHA antigo, simulação indevida e shard isolado; E6 prova sessão através dos clientes reais |

## Dependências e posse

E2 contém providers/composer/permissions/workspaces/memory/diagnostics. Seus testes usam runtime/host/bridge já entregues, sem chamar outra lane E2. Providers é exercitado por driver real do adapter; composer por pin/resolve; permissões por ação e executor I/O; workspaces por IDs reservados no registro autorizado; diagnostics por probes do runtime/bridge legado. O ciclo completo de threads chega em E3.

E3 contém threads/checkpoints/terminal/environments. Environments prova auth contra runtime E1, sem depender da nova implementação de threads da mesma etapa. A lane environments também possui `internal/harness-sessions/` no MiddlewareAuth. E4 reúne quatro serviços consumidores de E3 e seis UIs de domínios entregues em E2; E5 contém oito UIs de serviços entregues até E4. Nenhuma lane precisa importar código de uma irmã em andamento.

A integração é serial ao final de cada etapa, com base comum para todas as lanes e wiring de serviços nesse fechamento. E6 concentra o shell final. Diretórios globais, registry e locks não são editados concorrentemente. Schemas novos entre etapas exigem revisão serial antes de abrir lanes. A independência foi verificada no plano; a implementação ainda deverá demonstrar posse real dos arquivos nos PRs.

## Validação realizada e limites

A revisão verificou estrutura e versão das 15 RFCs, blocos YAML, referências de tipos, igualdade de tipos repetidos entre fases, snapshots próprios, numeração dos testes, grafo de dependências, pré-requisitos da matriz, posse dos módulos e links locais. Foram inspecionados os caminhos snapshot→eventos, composer→fila→adapter, action→approval→effect e pairing→grant→introspection→refresh→revoke. O arquivo original da regra de serialização foi preservado.

Há 139 testes numerados nas RFCs e 38 casos na matriz cumulativa, desdobrados por superfície. Cobertura exigida por gate: E0=3, E1=6, E2=12, E3=18, E4=35, E5=51, E6=56 pares caso/superfície. CONTRACT-00 também verifica o próprio agregador com relatórios inválidos. Esses números são exigências de cobertura, não testes de produto executados.

Nenhum runner novo, schema executável harness.v1 ou E2E de implementação foi executado nesta revisão: são entregas de E0 e das etapas seguintes. Os testes existentes de produto não comprovam estes endpoints futuros. A aceitação de E0 exige materializar os contratos fechados, compilar os helpers com os locks fixados, executar corpus/legado em processos e clientes reais e anexar relatório agregado com os três SHAs. Ausência de qualquer evidência mantém o gate aberto.

## Documentos normativos

[Contratos entre módulos](contratos-integracao-v0.2.md), [arquitetura](arquitetura-e-implementacao.md), [plano de worktrees](plano-worktrees.md), [matriz](matriz-verificacao.json), [rig e gates](testes-e2e.md) e [issues](issues.md). O cabeçalho de cada RFC incorpora os contratos entre módulos; entregar ambos ao gerar contratos por fase.
