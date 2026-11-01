# New Harness — revisão e testes determinísticos

Draft 0.2.0 · 2026-11-01. Os runners e testes abaixo são entregas futuras. Esta revisão documental não declara nenhum gate de implementação aprovado.

## Calendário executável

A fonte de verdade é [matriz-verificacao.json](matriz-verificacao.json). Cada cenário tem etapa inicial, dependências por fase e superfícies obrigatórias. Em cada gate executar cumulativamente todos os casos introduzidos até a etapa. A UI legada real é obrigatória em todos os gates; novos serviços são testados ponta a ponta por rede/processos e entram nos E2Es visuais somente quando suas fases /02 forem entregues.

E1 não usa provider inexistente: o teste SERVICE-0002 usa executor mínimo de escrita de arquivo temporário na fronteira I/O para provar receipt/outbox/worker/recovery reais. Provider adapter entra em E2; threads, streaming do provider e integração contexto→adapter entram em E3. O cliente base runtime/02 entra serialmente em E1; os demais módulos /02 entram em E4/E5; shell completo em E6. Não usar slot de UI para alegar teste de componente ainda não implementado.

| Cenário | Etapa | Tipo | Superfícies | Evidência |
| --- | --- | --- | --- | --- |
| LEGACY-00 | E0 | e2e | web, macos | UI legada real: enviar resposta fixture via bridge/MiddlewareAuth, reiniciar e restaurar sessão; wiki e MCP Evidence operantes |
| CONTRACT-00 | E0 | contract | service | Mesmo corpus positivo/negativo nos validadores JS/Swift; schemas fechados, registry de classes/owners, bootstrap local scoped, locks/build e casos de recusa do agregador de gates |
| SERVICE-0002 | E1 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0002 | E1 | e2e | web, macos | Testes 02-NN do cliente base runtime no host real: snapshot/replay, receipt aceito versus concluído, major incompatível e fallback legado; sem provider novo |
| SERVICE-0003 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0003 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0004 | E3 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0004 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0005 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0005 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0006 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0006 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0007 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0007 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0008 | E3 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0008 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0009 | E3 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0009 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0010 | E3 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0010 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0011 | E4 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0011 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0012 | E4 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0012 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0013 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0013 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0014 | E4 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0014 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0015 | E4 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0015 | E5 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| SERVICE-0016 | E2 | service-integration | service | Todos os testes 01-NN da RFC, incluindo snapshot em múltiplas páginas, store real, isolamento e falha/recovery |
| UI-0016 | E4 | e2e | web, macos | Todos os testes 02-NN da RFC pelo módulo real com serviço real; foco, erro, estado stale, segurança |
| CONTEXT-CHAIN | E3 | service-integration | service | Prepare/pin/queue/resolve/adapter: conferir bytes/roles/hash nos frames outbound; referência excluída ausente; crash entre pin e enqueue não perde contexto nem vaza pin |
| HISTORY-CHAIN | E4 | service-integration | service | MCP read e handoff leem mensagens completas de >100 itens; boundary estável durante append; cliente sem cache |
| AUTH-REAL | E3 | service-integration | service | MiddlewareAuth real: cliente limpo pareia e chama API; audience errada, refresh usado/expirado e token revogado recusados; indisponibilidade falha fechada |
| SHELL-CHAIN | E6 | e2e | web, macos | Shell final: projeto/worktree→contexto→aprovação→tool/task→diff/restore→PR fixture→captura/recall→fork→restart; verificar dados no provider, receipts, Git e memória |
| AUTH-SHELL | E6 | e2e | web, macos | Sessão real MiddlewareAuth pelo cliente limpo: grant, uso, refresh, revogação e parada de stream em 1000 ms; nenhuma credencial previamente injetada |
| PACKAGED | E6 | e2e | macos | Bundle real universal; hashes/ref após assinatura; 1 helper managed; external sem controle de processo; major incompatível preserva wiki/legado |

## Rig e fronteiras permitidas

NH-TEST cria runner POSIX `script/test_new_harness_e2e.sh`, Playwright/Chromium fixados e host macOS XCTest/XCUI com accessibility IDs. Usar PocketWiki Node/HTTP nativo, Kernel e MiddlewareAuth reais, com stores e Git temporários e portas bind(0) informadas por ready-file. Não usar .env/keychain/HOME reais. No E0–E2, sessão local de host é a credencial scoped definida em R4; auth remota nova só é exigida a partir de E3.

Fixtures podem substituir apenas provider externo/CLI, forge, rede, relógio, IDs e fronteiras I/O estritamente declaradas. Não substituir orchestrator, policy, adapter, normalizador, projector, snapshot/history ou checkpoint. Auth de domínio isolado pode usar fixture de emissão, mas AUTH-REAL e AUTH-SHELL obrigatoriamente usam issue/introspect/rotate/revoke reais do MiddlewareAuth. Nesses casos, só a identidade inicial de teste é semeada no store isolado pelo mecanismo de provisionamento real; bearer da sessão do cliente não é pré-instalado.

Transcrições de provider usam frames brutos e verificam outbound, não eventos de domínio pré-normalizados. Confirmar entrada que o adapter realmente enviou, inclusive anexos/roles e exclusões. Para crash, encerrar processo real e reabrir mesmo store. Para snapshot, apagar cache de cliente, criar 101 registros nos domínios que comportam esse volume; nos limitados (ex.: 32 workspaces), usar 2 registros e page_size=1; mutar entre páginas e comparar estado completo com snapshot+eventos pós-boundary; presença de texto na tela sozinha não prova ausência de duplicação/perda.

Sincronizar por receipt, evento persistido, sinal do processo e drain do worker (fila e item ativo). Relógio/IDs injetáveis; avançar tempo explicitamente, sem sleep, polling artesanal, waitForTimeout ou retry que esconda flaky. Esperas de UI aguardam condição acessível, sem decidir ordem de negócio por tempo. Deadline global 180000 ms por cenário; indisponibilidade de plataforma/helper exigido é falha de gate, nunca skip verde.

## Runner, agregação e revisão

CLI: `--stage E0|E1|E2|E3|E4|E5|E6 --surface service|web|macos|all --report-dir path`; default all. Exit 0 exige todos os casos da seleção local aprovados; exit 1 é falha de execução/asserção; exit 2 é configuração/dependência ausente. Um exit 0 de shard isolado não aprova gate.

O agregador `script/verify_new_harness_gate.sh --stage EN --reports paths...` compara exatamente os pares (id,surface) obrigatórios da matriz para a etapa, sem aceitar ausente/skip/duplicado conflitante. Cada par exige mesmo pocketwiki_sha, pocketkernel_sha, middlewareauth_sha, schema_sha256, fixture_sha256 e matrix_sha256. SHA de MiddlewareAuth é obrigatório porque auth/bridge legado já o usa; bundle real valida que o helper corresponde ao SHA testado. Rejeitar relatório de build anterior ou modos de simulação não permitidos no cenário. Só o agregador pode emitir gate_passed=true e liberar próxima etapa.

Relatório de shard: `{version:"0.2.0",stage:Stage,pocketwiki_sha:sha1,pocketkernel_sha:sha1,middlewareauth_sha:sha1,schema_sha256:sha256,fixture_sha256:sha256,matrix_sha256:sha256,seed:int,auth_mode:enum[host_local,fixture,real],cases:CaseResult[],exit_code:int}`. CaseResult = `{id:string,surface:enum[service,web,macos],status:enum[passed,failed],artifact_paths:string[]}`. AUTH-REAL/AUTH-SHELL exigem relatório auth_mode=real separado se houver shard com outro modo. AUTH-SHELL deve provar grant via UI + primeiro request + rotação + revogação, não somente introspecção de token semeado.

Guardar JUnit, trace browser, screenshot de falha, dump de receipts/eventos e logs redigidos com canários. artifact_paths relativos ao report-dir. Não publicar automaticamente artefatos contendo conversas/secrets. Revisor confere fronteiras, posse de arquivos, idempotência/recovery, ausência de secrets e cobertura das interfaces ligadas. Relatório deve indicar comandos executados e SHAs reais; usar SHA futuro placeholder invalida gate.

Regressão existente: `npm test`, `npm run test:memory:swift`, `script/validate_pocket_interop_contract.sh`, `script/ci.sh`, sem duplicar suites incluídas no ci.sh. Linux cobre Node/Kernel; macOS cobre Swift/app e release. Gates exigem ambos os conjuntos, além da matriz. E6 verifica migração v1→v2 e rollback da UI sem apagar v2, além de fluxo no shell de produção.

A revisão documental libera apenas o início de E0. NH-00 e NH-TEST permanecem abertos até entregar e testar os artefatos; gate E0 só fecha após relatório agregado real e revisão. Não fechar RFC pelo término do backend: exigir suas duas fases e o gate cumulativo correspondente.
