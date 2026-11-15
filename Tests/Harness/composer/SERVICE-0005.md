# Composer 0005/01 — handoff preliminar

Base PocketWiki `d98f09bc4ae667c96c093c9f0b09134326ebb435`; PocketKernel `582e216c13feb7485fa9620d9543b272ec3794b5`; MiddlewareAuth `04f44f62126c785f7b28718d2eff837c28cb65df`. RFC 0005 e cabeçalho R1–R7 versão 0.2.0. Esta entrega é parcial e não aprova gate.

## Reprodução

Na raiz da worktree, com Node e compilador C instalados:

```sh
node --test Tests/Harness/composer/composer.test.mjs
swiftc -typecheck Sources/PocketWikiMac/Services/Harness/Composer/ComposerDraftStore.swift
```

A suíte Node usa o serviço e stash reais em diretórios temporários privados, removidos ao término. A saída do runner contém nomes dos testes e contagens, sem conteúdo dos anexos ou credenciais. Em 2026-11-14: 22 testes passaram, nenhum skip; typecheck Swift sem saída, exit 0. Esses resultados não são uma execução do gate cumulativo nem provam os itens abaixo.

## Portas para integração

`ComposerService({dataDir, rootsFor, sourceResolver, secureReaderPath})` recebe diretório privado e policy de roots definida pelo host. `rootsFor(auth)` retorna somente roots explicitamente concedidos para a identidade autenticada; o serviço revalida a concessão antes de abrir e também após restart. `sourceResolver(reference, auth)` é a porta confiável para fontes não locais, inclusive quote: deve verificar autorização e proveniência e devolver `{bytes, mime, relative_path?}`. Fontes locais armazenam o root em stash privado, nunca no manifesto público.

O helper `src/harness/composer/secure-read.c` precisa ser compilado e instalado em caminho absoluto confiável, passado como `secureReaderPath`; sem ele, a leitura de arquivos falha fechada. A suíte compila o helper em diretório temporário e o remove no término.

O módulo `gateway.mjs` contém `ComposerGateway` e `ComposerPolicy`: o teste usa `LocalCredentialHost` real, verifica audience/scope/thread e consulta concessão explícita. O host deve manter as concessões atualizadas; objetos `auth` e `delegated_identity` não são credenciais e não podem ser aceitos do payload HTTP. Rotas devem usar schema fechado e conectar mutações ao ledger/CAS/receipt E1, sem logar segmentos. Resolve precisa receber identidade delegada verificada para a audience `pocketwiki.context.v1`. É necessário fornecer `rootsFor` e `sourceResolver` também na recriação do serviço. Integração de rotas, registry e shell pertence ao integrador.

## Pendências antes de liberar a lane

- O gateway autentica credenciais do `LocalCredentialHost` E1 e testa policy real. Falta conectar a execução das mutações ao ledger/receipts e CAS de agregado E1; não expor `ComposerService` diretamente a payload HTTP.
- A quote do teste usa resolver de teste; falta exercitar o serviço real de histórico/proveniência. A aplicação do evento de 01-05 ocorre em projeção de teste, não na projeção cliente real. As fronteiras de processo/rede ainda não foram exercitadas.
- A leitura usa descritor de root e `openat`/`O_NOFOLLOW` em cada componente. Falta ensaio de corrida com renomeação concorrente e revisão da política de concessão de roots, incluindo diretórios que um atacante possa mover para fora do root.
- O writer JSON serializa processos por diretório de lock e sincroniza os bytes antes de renomear. Se o processo morrer segurando o lock, o serviço retorna ERR_UNAVAILABLE até recuperação operacional controlada; ainda falta protocolo de recuperação e prova de durabilidade do diretório após crash. Eventos e tombstones ainda não têm retenção limitada. O store Swift não tem testes de persistência nem transação de erro.
- Contrato técnico gerado por fase, testes de corpus JS/Swift, testes de deadlines, dados sensíveis e evidência dos cenários pelo host real permanecem pendentes. Não há prova dos gates R1–R7 completos ou CONTEXT-CHAIN.
