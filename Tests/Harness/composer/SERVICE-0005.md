# Composer 0005/01 — handoff preliminar

Base PocketWiki `d98f09bc4ae667c96c093c9f0b09134326ebb435`; PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`; MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`. RFC 0005 e cabeçalho R1–R7 versão 0.2.0. Esta entrega é parcial e não aprova gate.

## Reprodução

Na raiz da worktree, com Node e compilador C instalados:

```sh
node --test Tests/Harness/composer/composer.test.mjs
swiftc -typecheck Sources/PocketWikiMac/Services/Harness/Composer/ComposerDraftStore.swift
swiftc Sources/PocketWikiMac/Services/Harness/Composer/ComposerDraftStore.swift Tests/Harness/composer/swift-store-test.swift -o /tmp/pocketwiki-composer-swift-test
/tmp/pocketwiki-composer-swift-test
rm /tmp/pocketwiki-composer-swift-test
swiftc Sources/PocketWikiMac/Services/Harness/Composer/ComposerDraftStore.swift Tests/Harness/composer/swift-corpus-test.swift -o /tmp/pocketwiki-composer-corpus-test
/tmp/pocketwiki-composer-corpus-test
rm /tmp/pocketwiki-composer-corpus-test
```

A suíte Node usa o serviço e stash reais em diretórios temporários privados, removidos ao término. A saída do runner contém nomes dos testes e contagens, sem conteúdo dos anexos ou credenciais. Em 2026-11-14: 45 testes passaram, nenhum skip; typecheck Swift sem saída, exit 0. O teste de store Swift compila e executa `swift-store-test.swift`, com um caso aprovado; corpus compartilhado de referências e drafts executado em JS/Swift: 12 casos aprovados por ambos. O teste adicional de HTTP privado foi executado isoladamente: 1 aprovado, incluindo anexo retido após TTL, referência excluída, cliente em outro processo, credencial com scope errado e unpin seguido de 409. Esses resultados não são uma execução do gate cumulativo nem provam os itens abaixo.

## Portas para integração

`ComposerService({dataDir, rootHandleFor, sourceResolver, secureReaderPath})` recebe diretório privado e policy de roots definida pelo host. Cada grant é `{path,fd}` com descritor de diretório previamente aberto e mantido pelo host; o caminho seleciona somente grant exato e o FD é a autoridade. `ComposerPolicy` vincula também device/inode e rejeita FD fechado ou reutilizado. Após restart o host reabre e concede novamente os FDs autorizados antes de resolver referências persistidas. `sourceResolver(reference, auth)` é a porta confiável para fontes não locais, inclusive quote: deve verificar autorização e proveniência e devolver `{bytes, mime, relative_path?}`. Fontes locais armazenam o root em stash privado, nunca no manifesto público.

Fontes de suporte: [Apple XNU flags](https://github.com/apple-oss-distributions/xnu/blob/xnu-11417.101.15/bsd/sys/fcntl.h), [XNU macOS 14 sem a flag](https://github.com/apple-oss-distributions/xnu/blob/xnu-10002.81.5/bsd/sys/fcntl.h), `man 2 open` e [openat2 Linux](https://man7.org/linux/man-pages/man2/openat2.2.html).

O helper `src/harness/composer/secure-read.c` precisa ser compilado e instalado em caminho absoluto confiável, passado como `secureReaderPath`; sem ele, a leitura de arquivos falha fechada. A suíte compila o helper em diretório temporário e o remove no término.

O módulo `gateway.mjs` contém `ComposerGateway` e `ComposerPolicy`: o teste usa `LocalCredentialHost` real, verifica audience/scope/thread e consulta concessão explícita. O host deve manter as concessões atualizadas; objetos `auth` e `delegated_identity` não são credenciais e não podem ser aceitos do payload HTTP. Rotas devem usar schema fechado e conectar mutações ao ledger/CAS/receipt E1, sem logar segmentos. Resolve precisa receber identidade delegada verificada para a audience `pocketwiki.context.v1`. É necessário fornecer `rootHandleFor` e `sourceResolver` também na recriação do serviço e manter os FDs válidos durante cada operação. Integração de rotas, registry e shell pertence ao integrador.

## Pendências antes de liberar a lane

- O gateway autentica credenciais do `LocalCredentialHost` E1 e testa policy real. Falta conectar a execução das mutações ao ledger/receipts e CAS de agregado E1; não expor `ComposerService` diretamente a payload HTTP.
- 01-01 usa trecho real de arquivo wiki autorizado, preservado por hash e relido após restart; referências a mensagens de thread dependem de `threads.history` E3. 01-05 agora usa `ComposerProjection` e eventos/snapshot verificados no schema real; falta exercício pelo transporte e cliente de E4. Processos independentes, SIGKILL e HTTP privado de pin/resolve foram exercitados; falta rede integrada ao Kernel.
- A leitura usa root concedido por FD e uma única resolução beneath do kernel: macOS `openat(O_RESOLVE_BENEATH|O_NOFOLLOW_ANY|O_UNIQUE)`; Linux `openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS|RESOLVE_NO_MAGICLINKS)` com verificação de hardlinks. O helper testa suporte no runtime e falha fechado sem fallback. **macOS 14, alvo declarado do produto, não oferece as flags necessárias: leitura de wiki/arquivos retorna ERR_UNAVAILABLE nessa plataforma.** Não há paridade até existir isolamento seguro comprovado ou mudança de alvo. No macOS 26.6.2 passaram testes de troca de symlink e reparent para fora com inode externo de link único, além de substituição de path e FD reutilizado. O teste concorrente não prova formalmente atomicidade contra todo interleaving de rename no XNU; revisão independente permanece obrigatória. Linux e macOS 14 não foram testados nesta máquina.
- O writer JSON serializa processos por lock e sincroniza os bytes antes de renomear. O lock usa arquivo com metadata instalado por hardlink atômico; outro processo recupera lock do mesmo host somente quando o PID deixou de existir. Dono ambíguo, host diferente ou reaper abandonado falham fechados e exigem recuperação operacional; o arquivo e diretório são sincronizados após escrita/rename; SIGKILL após commit confirma replay local; falta injeção de falha nos demais pontos de commit. Eventos são mantidos por 10 minutos ou enquanto necessários para snapshot ativo; tombstones ainda não têm retenção limitada. O store Swift tem teste de falha de escrita seguida de retry e reabertura; falta prova concorrente e de crash.
- O contrato técnico revisável está em `01_composer_dominio.md` nesta lane, para o integrador mover; corpus completo de todas as entidades/comandos em JS/Swift, deadlines, dados sensíveis e evidência dos cenários pelo host real permanecem pendentes. Não há prova dos gates R1–R7 completos ou CONTEXT-CHAIN.

## Porta proposta para o ledger Kernel

`startComposerHTTP({gateway})` fornece endpoint privado somente em loopback para `POST /v1/composer/pin` e `/v1/composer/resolve`: JSON fechado `{thread_id,input}`, bearer delegado, limite de 16 KiB e respostas no-store. Não logar bearer ou contexto; TLS/autenticação remota pertencem a E3. O host configura a URL a partir da porta local retornada; nunca aceitar URL da mensagem.

`ComposerGateway.execute({ bearer, thread_id, command })` é um handler interno para uma intenção já aceita pelo Kernel; não é rota pública nem faz CAS de agregado. O bearer deve ser delegado à audience `pocketwiki.context.v1`, com `context.read` e thread vinculado; o gateway autentica com o host E1 e aplica `ComposerPolicy` antes de acessar o store. `command` é o envelope fechado `{protocol_major:1,command_id,environment_id,expected_revision,operation,input}`. O handler aceita somente `composer.prepare`, operação `mutation` no registry. `composer.stage`, `composer.draft.save`, `composer.pin` e `composer.resolve` são portas `local` autenticadas por `ComposerGateway.callLocal`, sem ampliar o enum de commands. Resultado interno é `{result,duplicate}`; Kernel transforma isso no resultado tipado da operação e mantém receipt como autoridade.

Kernel deve, em uma transação própria, validar owner/scope/thread e CAS de `expected_revision`, gravar intenção com hash, receipt e outbox antes do I/O; mesmo command_id/hash devolve o receipt original, divergência retorna conflito. Worker entrega a mesma intenção e credencial delegada à porta. O composer serializa processos e grava efeito, hash da intenção e resultado na mesma substituição de arquivo; replay do mesmo owner/command_id/hash retorna resultado anterior, e payload divergente retorna `ERR_CONFLICT`. Depois da confirmação do composer, Kernel conclui receipt e publica a projeção/evento conforme sua transação. Se a resposta se perder, manter receipt pendente/uncertain e repetir somente a mesma intenção idempotente; nunca gerar novo command_id ou inferir sucesso por timeout. O `command_id` dentro de `composer.pin.input` identifica a intenção consumidora; pin é porta local idempotente.

Teste integrado exigido: subir Kernel E1 e host Composer reais com stores separados; registrar thread e credencial; enviar mutação por `/v1/harness/commands`; matar a ponte após persistência do composer e antes do ack; reiniciar, consultar receipt, reenviar a mesma intenção pelo outbox e confirmar um único efeito/revision e resultado idêntico. Repetir com hash alterado, `expected_revision` obsoleto e principal diferente, verificando ausência de efeito. Validar também snapshot/stream reais com boundary e duplicatas. Os testes locais de dois processos e replay após restart exercitam somente a metade Composer, não substituem esse teste.

A base E1 anuncia apenas `runtime.dispatch`, `runtime.receipt` e `runtime.events`; não há porta de registro de handler Composer. O registry classifica as complementares como `local`, deliberadamente fora do enum de `HarnessCommand`; o dispatcher rejeita essas operações e suas portas locais validam os schemas próprios. Não ampliar o wire por essa diferença.
