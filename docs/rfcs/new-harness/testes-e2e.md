# New Harness — revisão e E2E determinístico

Estado: Draft · versão 0.1.0. Os comandos novos desta página são entregas a implementar em NH-TEST; não são scripts disponíveis hoje. Nenhum teste futuro é declarado aprovado por este pacote documental.

## O que o gate comprova

Cada etapa testa a árvore resultante da união de todas as suas worktrees, em ambos os repositórios quando houver mudança de Kernel. Aprovação isolada de PR não substitui o gate. Um gate só libera a próxima etapa com SHA imutável, relatório, revisão e zero cenário obrigatório faltante.

E0 valida o fluxo legado real e o corpus do protocolo novo. E1 em diante exercita runtime novo e todos os módulos liberados cumulativamente. Um módulo futuro ainda desabilitado não é um skip; cenário só entra quando sua etapa está entregue, e continua obrigatório daí em diante.

## Rig reproduzível

NH-TEST cria `script/test_new_harness_e2e.sh` (POSIX sh), `Tests/NewHarnessE2E/` e runner browser com versão de Playwright e Chromium fixadas no `package-lock.json`. macOS usa host de teste do app com accessibility IDs e XCTest/XCUI, ou teste de integração da aplicação real pela camada acessível equivalente validada em E0. Em E0 escolher e fixar XCTest/XCUI como implementação de referência; sem automação macOS real o gate final não pode passar. Teste estático de markup, `vm` com DOM simulado ou apenas captura de screenshot não contam como E2E.

O runner cria diretório temporário para wiki, memória, ledger, perfis fake, logs e Git. Usa portas efêmeras (`bind(0)`) comunicadas por ready-file; não reutiliza `.env`, keychain, HOME nem stores reais. Define `XDG_DATA_HOME` e paths explícitos de teste sem alterar variáveis do shell do usuário. O app aceita paths e credential-provider de fixture apenas em host de teste, sem backdoor de produção.

Processos reais: PocketWiki Node ou HTTP nativo, PocketKernel compilado no SHA integrado, banco/store reais, cliente browser/app e Git/worktrees reais em diretório temporário. As únicas substituições são fronteiras externas: provider HTTP/CLI, forge, emissão de credencial da identidade de teste, clock, IDs e sinais de rede/processo. O fake de identidade continua passando por validação de principal/scope/audience real no servidor. Nunca substituir orchestrator, policy, adapter, normalizador, projector ou checkpoint por objetos que já retornam sucesso.

Transcrições guardam frames brutos do protocolo do provider, versão do CLI, sequência inbound/outbound e saídas/exit; fixtures não começam com eventos já normalizados do domínio. Provider inference e Codex agent têm corpus distintos. O adapter de produção interpreta os frames. Timeout de provider é injetado na fronteira; crash do servidor é encerramento real e reabertura com o mesmo store.

Clock lógico avança explicitamente por serviço de teste; IDs têm sequência conhecida por namespace. Ordem e sincronização usam evento persistido, receipt, drain do worker e estado acessível da UI. Sem `sleep`, `waitForTimeout`, polling artesanal ou retry para transformar teste flaky em verde. `expect` de UI pode aguardar condição acessível com deadline global; isso não serve para escolher ordem de eventos de negócio.

O harness expõe, apenas no processo de teste, controles tipados `advance_clock(ms)`, `release_provider_frame(id)` e `drain_effects()`. `drain_effects` aguarda fila e item atualmente executando; fila vazia sozinha não basta. Os controles manipulam somente fronteiras, não escrevem eventos finais ou contornam autorização.

## Cenários cumulativos

| ID | Introduzido | Fluxo observável e asserção externa |
| --- | --- | --- |
| NH-E2E-00 | E0 | abrir wiki e chat legado, enviar resposta inference fixture, recarregar e recuperar sessão; corpus JS/Swift aceita/rejeita os mesmos JSONs |
| NH-E2E-01 | E1 | browser envia intenção, Kernel persiste, provider responde em frames e UI acompanha; reconectar repete ID sem duplicar run; reiniciar processo recupera estado confirmado |
| NH-E2E-02 | E1 | crash após efeito externo aceito mas antes do resultado: estado uncertain visível e zero reexecução cega; leitura do receipt permite reconciliar |
| NH-E2E-03 | E2 | selecionar inference versus agent e conta/modelo corretos; capabilities ausentes bloqueiam operação; token canário não aparece em UI/logs/export |
| NH-E2E-04 | E2 | anexar página/quote, alterar fonte entre preview/envio, observar stale e draft preservado; symlink fora do root não é aberto |
| NH-E2E-05 | E2 | aprovar ação uma vez por hash/revisão e recusar replay; 2 projetos com termo igual retornam memória isolada; nota CAS não perde edição |
| NH-E2E-06 | E2 | criar 2 worktrees no mesmo base SHA, provar isolamento por arquivos e branches; repo com hook não executa setup; cleanup dirty é bloqueado |
| NH-E2E-07 | E3 | enfileirar A/B em run ativo, editar A, reiniciar, observar fila held e retomar FIFO explicitamente; cancel requested só vira stopped após confirmação |
| NH-E2E-08 | E3 | checkpoint before/after, edição humana após preview bloqueia restore; provider sem rollback deixa hashes intactos; journal interrompido resulta recovery_required |
| NH-E2E-09 | E3 | task real com exit 7, reattach terminal com mesmo ID, truncamento de scrollback e OSC52 bloqueado; input sem scope não chega ao processo |
| NH-E2E-10 | E3 | browser conecta environment remoto fixture, cai rede e retoma cursor sem fallback local; challenge reutilizado/revogado é negado |
| NH-E2E-11 | E3 | cliente MCP real inicia thread, UI recebe atividade, read-only não executa; fork/textual handoff preserva roles/ordem e omite mensagem inteira por budget |
| NH-E2E-12 | E4 | forge fixture recebe criação/comentário 1 vez após aprovação; head muda e bloqueia envio; settlement não ocorre com run ou aprovação pendentes |
| NH-E2E-13 | E4 | inbox ordenada, pin/archive/read persistentes; evento repetido gera 1 notificação; sem mudança não notifica |
| NH-E2E-14 | E5 | percorrer todos os módulos visuais por teclado em web 390/900/1440 e macOS compacto/regular; mesmo contrato produz mesma ação e bloqueio nas duas superfícies |
| NH-E2E-15 | E6 | shell de produção inteiro: escolher projeto/worktree → prompt+contexto → aprovação → tool/PTY → diff/checkpoint → PR draft fixture → memória/fork → reiniciar e retomar; preservar wiki/MCP Evidence/JSON v1 |
| NH-E2E-16 | E6 | binário empacotado real: refs/hashes correspondem à release, managed inicia só 1 helper, external nunca é controlado, major incompatível deixa leitor e legado utilizáveis |

Antes de UI nova estar integrada, os fluxos E1–E4 passam pelo slot de feature do host E0 que instancia o módulo real e o conecta à fachada real. Não é view mockada. E6 repete os cenários pelo shell de produção; passar no slot de teste não substitui esse último fluxo.

## Entradas e comandos do gate

Contrato proposto do runner:

```sh
POCKETKERNEL_SOURCE_DIR=/caminho/kernel-integrado \
  sh script/test_new_harness_e2e.sh --stage E3 --report-dir .build/new-harness-E3
```

Opções fechadas: `--stage E0|E1|E2|E3|E4|E5|E6`, `--report-dir <path>` e `--surface web|macos|both` (default both). Exit 0 somente se todos os cenários introduzidos até a etapa passaram; exit 1 para asserção/falha de runtime; exit 2 para configuração/capability/fixture ausente. Deadline global 180000 ms por cenário, sem override para esconder falha. Ausência de helper/sistema requerido é falha de gate, nunca sucesso com skip. Diretório de relatório deve estar sob workspace de teste autorizado.

Asserções de estado usam hashes, contagens de efeitos, sequências e respostas externas. Não comparar texto gerado por modelo vivo. Repetir uma execução com seed fixa é permitido para reproduzir defeito; não aceitar rerun verde sem resolver a causa original.

Regressão existente no gate integrado:

```sh
npm test
npm run test:memory:swift
./script/validate_pocket_interop_contract.sh
./script/ci.sh
```

`script/ci.sh` já engloba parte dos comandos anteriores; no CI executar a cobertura uma vez, sem duplicar trabalho por conveniência. Durante a implementação, lane roda só os testes da mudança + cenário próprio; gate roda a regressão completa sobre o SHA unido. Release E6 também valida build universal e empacotamento pelo fluxo atual. CI Linux valida Node/Kernel; gate macOS valida Swift/app e release. Uma plataforma verde não substitui a outra.

## Relatório e revisão

Relatório `gate.json` tem `{stage:string, pocketwiki_sha:sha1, pocketkernel_sha:sha1, schema_sha256:sha256, fixture_sha256:sha256, seed:int, scenarios:[{id:string,status:enum[passed,failed],artifact_paths:string[]}], exit_code:int}`. Guardar JUnit, trace do browser, screenshot de falha, log redigido e dump de receipts/eventos sem secrets. Paths são relativos ao report-dir; artefatos não saem automaticamente da máquina.

Revisor confere autoridade de domínio, idempotência, recuperação, revisão monotônica, permissão efetiva, ausência de secrets, compatibilidade v1 e posse de arquivos. Conferir também risco específico da etapa: E2 isolamento; E3 side effects/restore; E4 publicação; E5 acessibilidade; E6 empacotamento/migração. Se faltar implementação do Kernel, revisão ou E2E, manter gate aberto e impedir a próxima etapa. Fechar issue de feature só depois de fase 02 e gate cumulativo correspondente aprovados; a issue de gate é a evidência da união.
