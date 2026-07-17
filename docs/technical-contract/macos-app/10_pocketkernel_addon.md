# Add-on PocketKernel

O PocketWiki pode atuar como âncora de execução do PocketKernel no macOS. A distribuição composta leva o executável `pocketkernel` em `Contents/Helpers` e os dois módulos MCP do PocketWiki em `Contents/Resources/PocketWikiMCP`.

Isso remove o start manual no fluxo integrado, mas não transforma os repositórios em um monólito.

## Limite declarado

- PocketKernel continua dono do harness, da governança de saída e do endpoint `POST /v1/kernel`.
- PocketWiki continua dono da wiki, do servidor de conteúdo e das tools `wiki.search` e `wiki.get_document`.
- MiddlewareAuth continua dono da autenticação e configuração de providers.
- Cada projeto compila e executa sozinho. O add-on é um adaptador de processo e configuração, não uma dependência de código-fonte entre repositórios.
- No modo remoto, o PocketWiki não controla processo, MCP ou credenciais do PocketKernel externo.

## Modos

`POCKETWIKI_POCKETKERNEL_MODE` aceita:

| Valor | Comportamento |
|---|---|
| `automatic` | Usa um `/v1/kernel` saudável; se não existir, inicia o helper local. |
| `managed` | Inicia o helper empacotado. Só aceita HTTP em loopback. |
| `external` | Apenas valida e consome a URL informada. Nunca inicia processo. |
| `disabled` | Não consulta nem inicia PocketKernel. |

A sonda usa `GET /v1/kernel` e exige `405 Method Not Allowed`, que é o comportamento real do adaptador HTTP do PocketKernel. Um `200` genérico na mesma porta não é aceito como prova.

## MCP Evidence

PocketKernel inicia o MCP sob demanda por stdio; não existe uma porta MCP adicional. O add-on gera:

```text
~/Library/Application Support/PocketWiki/PocketKernel/pocketwiki-mcp-wrapper
```

O wrapper é `0700`, chama um Node.js explícito e preserva o script e o root como argumentos reais. `POCKETKERNEL_WIKI_MCP_ARGS` fica vazio. Isso contorna com segurança o parser atual baseado em espaços do PocketKernel e permite paths como `/Users/alguem/Minha Wiki`.

O painel **Servidor** confirma separadamente o serviço HTTP e a configuração do MCP. A configuração avançada da IA repete o status operacional sem duplicar controles de modo.

## Provider e MiddlewareAuth

No modo gerenciado, o PocketKernel não recebe a API key do LM Studio nem os tokens OAuth da OpenAI. O PocketWiki abre uma ponte OpenAI-compatible em uma porta aleatória de loopback e entrega ao Kernel somente um bearer efêmero, gerado por processo:

```text
PocketKernel
  -> ponte loopback do PocketWiki
  -> MiddlewareAuth /v1/projects/{projectId}/llm/responses
  -> LM Studio ou OpenAI
```

A ponte converte a requisição OpenAI-compatible do Kernel para o contrato canônico do MiddlewareAuth e normaliza a resposta de volta. Trocar provider, modelo ou raciocínio na UI atualiza a rota em runtime, sem reiniciar o PocketKernel. Modelos OpenAI e LM Studio são preferências separadas para não reaproveitar um identificador incompatível ao trocar de provider.

O check **Ponte provider** no painel Servidor confirma apenas o caminho interno Kernel → MiddlewareAuth. A autenticação real do provider é exibida e validada na área **IA**; assim um listener saudável não é apresentado como login válido.

O LM Studio pode exigir API key. Depois da configuração inicial, a credencial permanece sob responsabilidade do MiddlewareAuth e não precisa ser digitada novamente após reiniciar o PocketWiki. Atualizar status ou enviar uma pergunta nunca reaplica silenciosamente `LM_STUDIO_API_KEY` do ambiente; a credencial só é substituída quando o usuário informa uma nova chave na UI e aciona **Configurar**.

Os add-ons em modo automático/gerenciado sobem no bootstrap da aplicação; não dependem de abrir a aba Servidor. Ao trocar a pasta da wiki, somente um PocketKernel gerenciado pelo app é reiniciado para atualizar o root do wrapper MCP.

## Build e rastreabilidade

O builder fixa uma revisão imutável:

```sh
./script/build_pocketkernel_addon.sh
```

Para desenvolvimento local, a origem precisa conter essa revisão:

```sh
POCKETKERNEL_SOURCE_DIR=/caminho/pocketkernel ./script/build_and_run.sh --bundle
```

Também existem os overrides `POCKETWIKI_POCKETKERNEL_BINARY` e `POCKETWIKI_NODE_BINARY`. Não há descoberta automática de uma pasta irmã.

O builder exporta a revisão com `git archive` antes de compilar. Alterações não commitadas e o branch atualmente aberto no repositório local não entram no binário nem no hash publicado.

A revisão, arquiteturas e o SHA-256 do helper distribuído ficam em `Contents/Resources/Addons/PocketKernel/pocketkernel.build.json`. O helper é universal quando `MACOS_ARCHS="arm64 x86_64"`; o SHA-256 é recalculado depois da assinatura Mach-O e antes da assinatura externa do `.app`.

Uma distribuição deliberadamente sem o add-on usa:

```sh
POCKETWIKI_INCLUDE_POCKETKERNEL_ADDON=0 ./script/build_and_run.sh --bundle
```

O ref canônico precisa existir no Git remoto para o CI ser reproduzível. Uma cópia apenas local do repositório não satisfaz o contrato de release.

## Falhas, logs e atualização

O PocketWiki valida o manifesto e o SHA-256 do helper empacotado antes de executá-lo. Falha de inicialização gera um alerta global no app e uma entrada `ERROR` no log da aba **Servidor**. Se um processo já validado encerrar inesperadamente, o supervisor registra `WARNING` e tenta recuperá-lo até três vezes em uma janela de 60 segundos, com backoff de 1, 5 e 15 segundos. Recuperação bem-sucedida gera uma entrada `INFO`, sem modal. Só a falha definitiva ou o crash loop gera alerta global; a modal contém um resumo curto e direciona ao log, sem despejar a saída bruta na interface. O arquivo completo fica em:

```text
~/Library/Application Support/PocketWiki/PocketKernel/pocketkernel.log
```

O PocketKernel não se atualiza de forma independente dentro do PocketWiki. A unidade de atualização é a release completa do PocketWiki: o manifesto público registra o ref e o SHA-256 dos dois add-ons. A aba **Servidor** compara a revisão em execução com a revisão da próxima release e oferece a atualização canônica quando houver mudança.

O instalador recusa a atualização se faltar qualquer helper ou manifesto, se um SHA-256 divergir ou se o manifesto interno não corresponder ao manifesto publicado na release. A substituição do `.app` é atômica; ao encerrar a versão atual, ela encerra os processos que gerencia, e a nova versão inicia os helpers validados no próximo launch.
