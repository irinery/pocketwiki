# New Harness — incrementos e worktrees para GPT-6-Luna

Estado: Draft · versão 0.2.0. Plano de implementação futura; nenhuma worktree de implementação nem execução de agente foi iniciada por este pacote documental. Usar GPT-6-Luna como solicitado; o identificador de execução é resolvido no catálogo da ferramenta usada, sem inventar um slug de API.

## Independência verificável

Cada linha é uma lane com diretório exclusivo, contrato já congelado e teste próprio. Um agente por worktree; máximo sugerido de 3 lanes simultâneas para limitar custo de integração. Linhas da mesma etapa não consomem mudanças umas das outras. Todos partem do mesmo SHA verde da etapa anterior. Se surgir dependência entre duas lanes, movê-la para a etapa seguinte ou criar uma base serial nova antes de iniciar as duas; não chamar de paralelismo quando uma precisa esperar a outra.

Backend/cliente de uma mesma RFC são sequenciais. O trabalho no Kernel e no PocketWiki de uma lane usa dois checkouts com refs explícitas, não git worktree compartilhada entre repositórios. São tarefas coordenadas pela mesma issue do PocketWiki, com links dos commits/PRs do Kernel registrados nela.

Nenhuma lane de domínio modifica arquivos globais de integração, schemas/lockfiles ou diretórios de outra lane. A lane de memória é a única autorizada a evoluir `src/memory/store.mjs` e `PocketMemoryStore.swift`; as demais só consomem sua facade congelada. Essa exceção tem dono único em E2.

## Etapas e dependências

| Etapa | Lanes factíveis | Base exigida | Saída antes do gate |
| --- | --- | --- | --- |
| E0 | NH-00 contratos/registro/locks; depois NH-TEST rig E2E, serial | árvore atual documentada | schemas fechados, registry modular, fixtures, runner e baseline legado |
| E1 | RFC-0002/01 ledger/outbox; depois RFC-0002/02 API/projeção base, serial | gate E0 | intenção durável, recovery, receipt, SSE e cliente base reais |
| E2 | 0003/01 providers; 0005/01 composer; 0006/01 permissões; 0007/01 workspaces; 0013/01 memória; 0016/01 diagnóstico | gate E1 | seis serviços independentes sobre runtime e schemas congelados |
| E3 | 0004/01 threads; 0008/01 checkpoints; 0009/01 terminal; 0010/01 environments | gate E2 | quatro domínios consumindo somente APIs já integradas |
| E4 | 0011/01 MCP; 0012/01 handoffs; 0014/01 Git/PR; 0015/01 navegação; fase 02 de 0003,0005,0006,0007,0013,0016 | gate E3 | 4 domínios + 6 módulos UI com paths exclusivos |
| E5 | fase 02 de 0004,0008,0009,0010,0011,0012,0014,0015 | gate E4 | 8 módulos UI exercitados em host real por slots |
| E6 | integração de shell/rotas/build/migração, 1 lane serial | gate E5 | fluxo inteiro no shell de produção e release composta verificável |

São 30 fases de RFC, 2 habilitadores e 7 gates. RFC-0002/02 é infraestrutura de transporte/projeção, não um widget paralelo com o restante do app. As dez lanes de E4 e as oito lanes de E5 podem ser executadas em lotes de até 3, sempre partindo da mesma base da etapa. Não integrar lote e usar essa base só para o próximo lote da mesma etapa: isso criaria dependência oculta. A união acontece depois de todas as lanes dessa etapa concluírem.

## Matriz de posse

Para fase 01, o PocketWiki usa `src/harness/<module>/`, `Sources/PocketWikiMac/Services/Harness/<SwiftModule>/`, `Tests/Harness/<module>/`. Para fase 02, usa `src/harness-ui/<module>/`, `Sources/PocketWikiMac/Views/Harness/<SwiftModule>/`, `Tests/HarnessUI/<module>/`. Novos serviços reais do Kernel ficam em `internal/harness/<module>/` (dir lógico `harness/<module>` nas RFCs), com package Go compatível, sem hífen no nome do package.

| RFC | module / SwiftModule | Backend em | Dependências externas à própria lane |
| --- | --- | --- | --- |
| 0002 | runtime / Runtime | Kernel | NH-00 + NH-TEST |
| 0003 | providers / Providers | Kernel + adapters MiddlewareAuth | runtime |
| 0004 | threads / Threads | Kernel | runtime + providers + composer + permissions + workspaces |
| 0005 | composer / Composer | PocketWiki | runtime |
| 0006 | permissions / Permissions | Kernel | runtime |
| 0007 | workspaces / Workspaces | Kernel | runtime |
| 0008 | checkpoints / Checkpoints | Kernel | runtime + providers + permissions + workspaces |
| 0009 | terminal / Terminal | Kernel | runtime + permissions + workspaces |
| 0010 | environments / Environments | conector PocketWiki + sessão Kernel/MiddlewareAuth | runtime + permissions |
| 0011 | orchestrator-mcp / OrchestratorMcp | Kernel | runtime + threads + permissions + environments |
| 0012 | handoffs / Handoffs | Kernel | runtime + providers + threads.history + facade memória |
| 0013 | memory / Memory | PocketWiki | runtime |
| 0014 | source-control / SourceControl | Kernel | runtime + threads + permissions + workspaces + checkpoints |
| 0015 | navigation / Navigation | Kernel | runtime + threads |
| 0016 | diagnostics / Diagnostics | fachada PocketWiki/Kernel | runtime |

MCP e handoff foram movidos para E4. Ambos dependem da porta de leitura `threads.history`, entregue/testada em E3; MCP remoto também depende de environments/01. Um dispatcher genérico não substitui o histórico. Nenhuma lane E4 consome a implementação de outra lane E4: os clientes UI dessa etapa pertencem aos domínios já entregues em E2.

Threads E3 consome composer.prepare/resolve/pin, provider binding, policy e workspace registry de E2. Checkpoints consome adapter de rollback, policy e lease também de E2. Terminal usa lease/policy E2. Environments possui exclusivamente os novos endpoints de sessão no MiddlewareAuth; nenhuma outra lane E3 edita esse repo. O integrador registra serviços ao fechar cada etapa e mantém a integração do shell para E6.

Os E2Es cumulativos sempre incluem a UI legada real. Para funções novas, E1–E3 testam integração de serviços pela rede/processos reais, sem fingir existência de módulos visuais futuros. E4/E5 acrescentam UI /02; E6 repete no shell final. Matriz executável em `matriz-verificacao.json` e detalhes em `testes-e2e.md`.

## Tamanho das tarefas para Luna

Uma lane entrega 1 interface principal, interfaces complementares, persistência e todos os cenários numerados de sua fase (incluindo novos casos de integração da versão 0.2.0). Para domínios maiores, dividir commits dentro da mesma worktree em sequência; não abrir agentes concorrentes no mesmo pacote. Cada subpasso tem uma saída executável:

| Lane maior | Subpassos seriais dentro da lane |
| --- | --- |
| runtime/01 | ledger + migrations + receipt → transação outbox/projeção → worker recovery/uncertain |
| runtime/02 | endpoints/snapshot/SSE → cliente JS/Swift base → replay/reconnect/compat legado |
| providers/01 | catálogo/binding inferência atual → adapter Codex opcional e lock de protocolo → capacidades e resume/interrupt |
| checkpoints/01 | captura refs/diff → preflight/preview → journal e restore coordenado/falha |
| terminal/01 | task argv/reap → PTY/cursor/buffer → auth/input/close e segurança do renderer |
| environments/01 | identidade/challenge → conexão/cache/cursor → revogação e falha de rota |
| source-control/01 | leitura/link/head/checks → preview/execute/reconciliação → settlement por CAS |
| módulo UI /02 | store e estado acessível → ações/feedback e foco → cenário browser/macOS pelo slot |

Não estimar independência por quantidade de arquivos ou tamanho de prompt. Se o agente não consegue demonstrar uma transição observável ao terminar subpasso, a tarefa ainda está ampla e deve ser quebrada antes de continuar. Campos wire não são redesenhados dentro dessas subdivisões.

## Como abrir as worktrees

Exemplo POSIX sh para uma lane após o gate anterior. `NH_BASE_SHA` deve ser o SHA do relatório do gate, nunca um branch que continua mudando.

```sh
NH_BASE_SHA='<sha-do-gate-E1>'
NH_WORK_ROOT='../pocketwiki-new-harness'
mkdir -p "$NH_WORK_ROOT"
git worktree add -b codex/nh-e2-0003-01 \
  "$NH_WORK_ROOT/e2-0003-01" "$NH_BASE_SHA"
```

O valor entre `<...>` é instrução de execução futura substituída pelo relatório, não um campo indefinido da especificação. Repetir com nome único para cada lane. No repo Kernel usar seu próprio `NH_KERNEL_BASE_SHA` do mesmo gate. Em E0, usar o SHA documental/handoff imutável autorizado em e0-handoff.md, mesmo antes do merge em main. A aprovação do gate E0 é pré-condição de E1, nunca da implementação de E0.

## Prompt de delegação sugerido

```text
Modelo: GPT-6-Luna.
Implemente apenas RFC-NNNN fase NN, issue vinculada, sobre os SHAs do gate anterior.
Leia o cabeçalho + bloco da fase e contratos-integracao-v0.2.md.
Os contratos estão congelados em harness.v1; não crie campos ou comportamento implícito.
Edite somente os diretórios da lane na matriz de posse.
Escreva primeiro todos os cenários observáveis do contrato e use os fixtures de NH-TEST.
Mantenha adapters/policy/store/projeções reais; substitua apenas fronteiras externas.
Não altere shell/rotas/locks/scripts globais e não consuma branch de outra lane da etapa.
Entregue commits, comandos/resultados dos testes, SHAs, arquivos tocados e instrução
de integração. Se precisar de contrato novo, pare essa alteração específica e reporte
o bloqueio na issue; não crie dependência oculta entre lanes.
```

É um plano de delegação, não autorização para postar mensagens em serviços externos nem para agentes publicarem comentários/merges de produto durante testes. Forge fixture é obrigatório no E2E.

## Integração e gates

Para cada E0–E6 existe uma issue de gate no milestone. O integrador cria `codex/nh-eN-integration` sobre a base anterior, une commits das lanes e resolve conflitos de integração. Ele pode editar somente wiring/registro/global necessário à etapa; se descobrir erro de domínio, devolve à lane e traz o commit corrigido. Não expandir escopo silenciosamente ao resolver conflito.

1. Conferir matriz de arquivos e dependências; todas as lanes referenciam mesma base.
2. Unir também PRs do Kernel em branch de integração própria quando aplicável; fixar os SHAs de PocketWiki, Kernel e MiddlewareAuth.
3. Rodar E2E cumulativo da etapa, regressões e revisão conforme `testes-e2e.md`.
4. Salvar relatório/artefatos redigidos, registrar SHAs e revisão na issue de gate.
5. Somente com gate aprovado integrar a etapa e liberar a próxima base. Não fechar RFC só porque backend/01 terminou.

O integrador de cada etapa registra os serviços nas rotas reais. E6 concentra o shell e o pin final dos helpers. Módulos UI só são testados após suas fases /02; E6 prova o produto inteiro com os mesmos módulos. Não usar branches paralelos para editar simultaneamente `wiki-cockpit.html`, `LocalAIChatSession.swift` ou o workflow.

Mudança de contrato entre etapas exige patch no schema, fixtures JS/Swift e nova revisão do gate afetado. Mudança major cria versão nova; não editar contratos congelados e esperar que merge resolva compatibilidade.

## Escopo da liberação E0

A revisão 0.2.0 pode liberar o início de NH-00/NH-TEST, não o fechamento do gate E0. E0 ainda precisa entregar schemas, validadores, registry, credencial local scoped e rig real, executar a matriz e registrar os SHAs. E1 depende da aprovação desse gate. MiddlewareAuth possui SHA próprio registrado em qualquer etapa que o execute; sua emissão de sessão nova é entregue por environments/01 em E3.

## Coordenação atual da E0

[e0-handoff.md](e0-handoff.md) autoriza a base NH-00 para NH-TEST sem exigir merge em main, fechamento da issue #21 ou aprovação prévia de E0. Define um único escritor por worktree. Esta decisão substitui qualquer condição anterior conflitante.
