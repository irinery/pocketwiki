# Add-on MiddlewareAuth

## Objetivo

O PocketWiki pode atuar como âncora de execução do MiddlewareAuth no macOS. A distribuição composta leva o executável `middleware-codex-oauth` em `Contents/Helpers` e o inicia sob demanda quando a área de IA precisa do contrato de autenticação.

Isso elimina o start manual do MiddlewareAuth, mas não funde os dois projetos.

## Limite entre os apps

- O MiddlewareAuth continua dono de OAuth, credenciais de providers, armazenamento de tokens e das APIs `/v1/projects/*`.
- O PocketWiki conhece somente o contrato HTTP público e o ciclo de vida do processo filho que ele mesmo iniciou.
- O PocketWiki não importa packages internos, não lê arquivos de estado e não usa o checkout local de `../middlewareAuth`.
- Uma instância externa saudável sempre pode ser usada. O PocketWiki não encerra, reinicia nem altera processos externos.
- A ausência do add-on não impede o PocketWiki de abrir, servir ou editar wikis. Apenas a autenticação via MiddlewareAuth fica indisponível até existir um endpoint externo.
- O MiddlewareAuth compila e opera sozinho. Nenhuma mudança no PocketWiki é requisito para o servidor standalone.

O contrato canônico das rotas permanece no repositório MiddlewareAuth. Este documento define somente o adaptador e a responsabilidade do PocketWiki.

## Login OpenAI no app

O PocketWiki inicia o provider OpenAI pelo contrato canônico `POST /v1/projects/{projectId}/llm/login`, usando device code no add-on local. O client público do Codex não aceita o callback dinâmico `localhost:18787` usado pelo helper; tentar OAuth PKCE nesse endereço resulta em `authorize_hydra_invalid_request`. O app não recebe authorization code, access token ou refresh token.

No polling, o add-on envia os campos atuais exigidos pela OpenAI (`device_auth_id` e `user_code`), trata `deviceauth_authorization_pending` como estado transitório e mantém sessões pendentes consultáveis sem erro público. Isso evita transformar uma autorização ainda aguardando o usuário em `ERR_LLM_PROVIDER_UNAVAILABLE` ou encerrar a conexão HTTP.

Depois de abrir o navegador, o app conserva somente a `loginSessionId` e consulta `GET /v1/projects/{projectId}/llm/login-sessions/{id}` até um estado terminal. `authenticated` conclui o fluxo; `failed` e `expired` exibem o código público retornado pelo MiddlewareAuth. Uma página de sucesso no navegador não é tratada isoladamente como autenticação concluída: o perfil precisa estar persistido e confirmado por `/auth/openai/status`.

OAuth PKCE continua implementado no MiddlewareAuth para clientes cujo redirect esteja registrado, mas não é usado pelo app macOS integrado enquanto o callback do add-on não fizer parte da allowlist do client OAuth.

## Resolução em runtime

`POCKETWIKI_MIDDLEWARE_AUTH_MODE` aceita:

| Modo | Comportamento |
| --- | --- |
| `automatic` | Usa endpoint externo se o health check responder; caso contrário inicia o add-on empacotado. |
| `managed` | Inicia o add-on quando o endpoint não estiver saudável. Só aceita URL HTTP em loopback. |
| `external` | Nunca inicia processo; exige uma instância já disponível. |
| `disabled` | Não consulta nem inicia MiddlewareAuth. |

O padrão é `automatic`. A URL continua vindo de `MIDDLEWARE_BASE_URL`, com padrão `http://127.0.0.1:18787`.

A aba **Servidor** é o painel operacional do add-on. Ela mostra separadamente:

- resposta do contrato `/healthz`;
- validação da senha em uma rota autenticada;
- endpoint efetivamente usado;
- PID quando o processo pertence ao PocketWiki;
- modo automático, gerenciado neste Mac, remoto ou desligado.

Verde significa que serviço e autenticação foram confirmados. Um health check verde com senha amarela não é tratado como integração funcional.

No modo remoto, a senha precisa ser emitida e configurada no servidor remoto. O PocketWiki não tenta alterar credenciais de processos que não iniciou. O endpoint remoto deve ser publicado separadamente, preferencialmente por HTTPS, VPN ou reverse proxy.

Para desenvolvimento, `POCKETWIKI_MIDDLEWARE_AUTH_BINARY` pode apontar explicitamente para um executável compatível. Não existe descoberta implícita de pasta irmã.

## Estado e segurança

No modo gerenciado, o PocketWiki cria `MIDDLEWARE_SECRET_KEY` e `MIDDLEWARE_CLIENT_TOKEN` aleatórios. Eles ficam em:

```text
~/Library/Application Support/PocketWiki/MiddlewareAuth/
```

O diretório e o subdiretório `state/` usam permissão `0700`; o arquivo de credenciais do âncora usa `0600` e fica fora do `state/` pertencente ao MiddlewareAuth. O processo recebe secrets apenas pelo ambiente. O bind e o callback OAuth permanecem em loopback, e o PocketWiki nunca exibe ou grava os valores em log.

O botão **Gerar nova senha** existe somente para o helper gerenciado. Ele mantém `MIDDLEWARE_SECRET_KEY` para não invalidar os tokens OAuth criptografados, troca apenas `MIDDLEWARE_CLIENT_TOKEN`, reinicia o processo e valida a nova senha antes de confirmar. Se a validação falhar, a credencial anterior é restaurada.

## Construção do artefato composto

`script/build_middleware_auth_addon.sh` compila o entrypoint público a partir de uma revisão Git fixa e gera um binário universal. Em release, o script usa `go install pacote@ref` e não altera `go.mod`/`go.sum` do PocketWiki.

```sh
./script/build_middleware_auth_addon.sh
POCKETWIKI_SIGN_MODE=adhoc ./script/build_and_run.sh --verify
```

Para validar uma revisão local ainda não publicada, o builder exporta exatamente o commit solicitado com `git archive`; alterações não commitadas do checkout irmão continuam excluídas:

```sh
MIDDLEWARE_AUTH_SOURCE_DIR=/caminho/middlewareAuth \
  POCKETWIKI_SIGN_MODE=adhoc ./script/build_and_run.sh --verify
```

Os builders do `.app` e do DMG incluem o add-on por padrão. Para construir deliberadamente uma distribuição PocketWiki-only:

```sh
POCKETWIKI_INCLUDE_MIDDLEWARE_AUTH_ADDON=0 ./script/build_and_run.sh --bundle
```

Também é possível fornecer um artefato previamente validado:

```sh
POCKETWIKI_MIDDLEWARE_AUTH_BINARY=/caminho/middleware-codex-oauth \
  ./script/build_middleware_auth_addon.sh
```

A revisão consumida fica registrada em `Contents/Resources/Addons/MiddlewareAuth/middleware-codex-oauth.build.json`; `Contents/Helpers` contém somente o executável assinável.

## Falhas, logs e atualização

O PocketWiki valida o manifesto e o SHA-256 do helper empacotado antes de executá-lo. Falha de inicialização ou credencial inválida gera um alerta global no app e uma entrada `ERROR` no log da aba **Servidor**. Se um processo já validado encerrar inesperadamente, o supervisor registra `WARNING` e tenta recuperá-lo até três vezes em uma janela de 60 segundos, com backoff de 1, 5 e 15 segundos. Recuperação bem-sucedida gera uma entrada `INFO`, sem modal. Só a falha definitiva ou o crash loop gera alerta global; a modal contém um resumo curto e direciona ao log, sem despejar requisições HTTP na interface. A saída própria do processo fica disponível em:

```text
~/Library/Application Support/PocketWiki/MiddlewareAuth/middleware-auth.log
```

O MiddlewareAuth não se atualiza de forma independente dentro do PocketWiki. A unidade de atualização é a release completa do PocketWiki: o manifesto público da release registra o ref e o SHA-256 do MiddlewareAuth e do PocketKernel. A aba **Servidor** compara a revisão em execução com a próxima release e informa se o helper será trocado.

Antes de instalar uma atualização, o PocketWiki exige os dois helpers, seus manifestos internos e os hashes correspondentes. Quando a release publica metadados dos add-ons, eles também precisam ser idênticos aos manifestos internos. Qualquer divergência cancela a instalação. Depois da troca atômica do `.app`, os processos antigos são encerrados com o app atual e os novos helpers sobem no próximo launch.
