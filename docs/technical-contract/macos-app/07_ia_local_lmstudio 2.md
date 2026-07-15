# 07 — IA governada com PocketKernel e fallback LM Studio

## 2.1 — O que é

Tela e serviço para conversar com uma IA local governada pelo PocketKernel. O LM Studio direto existe só como fallback/debug OpenAI-compatible.

Direção obrigatória do fluxo governado:

```text
PocketWiki UI/app ou curl
  -> PocketKernel /v1/kernel
  -> PocketKernel chama PocketWiki MCP via stdio
  -> PocketWiki MCP devolve evidência
  -> PocketKernel chama LLM
  -> PocketKernel monta resposta governada
```

Regra crítica: PocketWiki MCP não inicia PocketKernel, não abre porta HTTP e não chama LLM. O MCP é ferramenta stdio iniciada pelo PocketKernel. Se a UI do PocketWiki precisar participar desse fluxo, ela deve chamar `POST /v1/kernel` ou o proxy local `/api/kernel/query`.

Responsabilidades explícitas:
- usar PocketKernel como provedor padrão da aba IA;
- chamar `POST /v1/kernel` com `{ text, channel, app_id, user_id }`;
- aceitar resposta JSON do Kernel com `profile_used`, `missing_evidence` e conteúdo em campos comuns (`answer`, `response`, `text`, `content`, `result.*`);
- expor `POCKETKERNEL_BASE_URL`, com default `http://127.0.0.1:8080`;
- no servidor PocketWiki, prover `/api/kernel/query` para que o browser remoto chame o PocketKernel do mesmo host do servidor;
- manter o caminho `UI -> PocketKernel -> MCP -> LLM` explícito em README e status operacional;
- listar modelos carregados via `GET /v1/models`;
- enviar conversa via `POST /v1/chat/completions` com `stream: true`;
- montar contexto automático da wiki antes de cada pergunta, com fallback para escopos manuais;
- manter o modo `Auto` preso ao índice: perguntas sobre wiki que não encontram página relacionada ainda recebem snapshot do índice e instrução explícita para não inventar;
- reaproveitar `LM_STUDIO_BASE_URL`, `LM_STUDIO_API_KEY`, `LM_API_TOKEN` e `LM_STUDIO_MODEL` do ambiente ou `.env`, sem persistir token em `UserDefaults`;
- aceitar listas de modelos nos formatos `data`, `models`, array raiz, objeto com `id`/`name`/`model` ou string simples;
- renderizar tokens parciais em lotes curtos para evitar travar SwiftUI;
- aceitar resposta não-streaming JSON quando o LM Studio/proxy devolver `application/json` apesar de o request pedir `stream: true`;
- renderizar `reasoning`, `finish_reason`, `usage` e modelo quando o servidor retornar esses campos;
- enviar mensagem com `Enter` e inserir quebra de linha com `Shift+Enter`;
- permitir cancelar resposta em andamento;
- oferecer reset anti-alucinação, limpando conversa/contexto, voltando escopo para `Auto` e temperatura para `0.2`;
- manter layout da aba IA fiel ao web: hero no topo, conversa como card principal, rail lateral e cards `LM Studio`/`Contexto` recolhíveis;
- permitir LM Studio em localhost, mDNS `.local` ou rede privada;
- bloquear endpoint público/remoto nesta fase.

Não é responsabilidade deste componente:
- carregar, baixar ou descarregar modelos no LM Studio;
- chamar APIs externas/cloud;
- fazer RAG vetorial/embeddings;
- executar MCPs direto na UI;
- persistir token secreto.

## 2.2 — Testes obrigatórios

TESTE AI-00
dado:    aba IA no estado padrão
quando:  o usuário envia pergunta
então:   o request sai para PocketKernel `/v1/kernel` ou `/api/kernel/query`, não para `/api/ai/chat`

TESTE AI-01
dado:    endpoint `http://127.0.0.1:1234/v1`
quando:  o app monta URL de chat
então:   a URL final é `/v1/chat/completions`

TESTE AI-01b
dado:    endpoint `http://127.0.0.1:1234`
quando:  o app monta URL de modelos
então:   a URL final é `/v1/models`

TESTE AI-02
dado:    endpoint `https://example.com/v1`
quando:  o usuário tenta usar a IA
então:   o cliente rejeita antes de enviar contexto

TESTE AI-02b
dado:    endpoint `http://192.168.2.20:1234/v1`
quando:  o usuário tenta usar a IA
então:   o cliente aceita por ser IP de rede privada

TESTE AI-03
dado:    página `A` com link resolvido para `B`
quando:  o escopo escolhido é `Links`
então:   o contexto inclui `A` e `B`, mas não páginas sem relação

TESTE AI-04
dado:    contexto maior que o limite configurado
quando:  o prompt é montado
então:   o contexto é truncado e sinalizado

TESTE AI-05
dado:    resposta streaming do LM Studio
quando:  chunks `data:` chegam
então:   o texto da resposta é atualizado em lotes e metadados de reasoning/usage são preservados quando existirem

TESTE AI-06
dado:    pergunta sobre termo presente em uma página da wiki
quando:  o escopo é `Auto`
então:   o app consulta o índice, escolhe páginas prováveis e envia só excertos relevantes

TESTE AI-07
dado:    `.env` com base URL, token e modelo
quando:  a aba IA inicializa
então:   a configuração é carregada em memória e o token não é persistido

TESTE AI-08
dado:    `/v1/models` retorna `models`, `data`, `name`, `id` ou string
quando:  o cliente interpreta a resposta
então:   modelos de chat são reconhecidos e modelos de embedding são filtrados

TESTE AI-08b
dado:    `/v1/chat/completions` retorna JSON comum com `choices[0].message.content`
quando:  o cliente interpreta a resposta
então:   o conteúdo é exibido em vez de erro de streaming vazio

TESTE AI-09
dado:    pergunta de wiki sem página candidata
quando:  o escopo é `Auto`
então:   o contexto continua em modo wiki, inclui snapshot do índice e instrui o modelo a não preencher lacuna com conhecimento externo

TESTE AI-10
dado:    PocketKernel configurado com `POCKETKERNEL_WIKI_MCP_COMMAND=node` e `POCKETKERNEL_WIKI_MCP_ARGS=".../pocketwiki-mcp-server.mjs --root /wiki"`
quando:  a UI envia pergunta operacional
então:   a resposta governada indica `profile_used=wiki` e `missing_evidence=[]` quando há evidência confiável

TESTE AI-11
dado:    MCP indisponível ou sem documento confiável
quando:  a UI envia pergunta que exige status operacional
então:   a resposta do Kernel preserva `missing_evidence`, incluindo `contexto_requerido_indisponivel` ou `fonte_confiavel_de_status_operacional`

## 2.3 — Implementação

Estruturas:

```yaml
LocalAIProvider:
  enum:
    - pocketKernel
    - lmStudio

LocalAIView:
  responsabilidade: coordenar estado, preferências, bootstrap runtime e ações

LocalAIWorkspaceShell:
  responsabilidade: layout responsivo único da aba IA
  modos:
    - regular: hero + conversa + rail + painel lateral
    - compact: conversa + rail/painel em overlay

LocalAIChatPanel:
  responsabilidade: cabeçalho, mensagens, composer, reset e envio

LocalAISidePanelContent:
  responsabilidade: cards recolhíveis de LM Studio e Contexto

LocalAIContextScope:
  enum:
    - automatic
    - currentPage
    - linkedPages
    - wikiDigest

LocalAIContextPayload:
  title: String
  body: String
  includedPaths: [String]
  characters: Int

LocalAIChatMessage:
  role: enum(system, user, assistant)
  content: String
  isStreaming: Bool

PocketKernelClient:
  query(baseURL, text, channel, appID, userID)
  endpoint_default: http://127.0.0.1:8080/v1/kernel
  proxy_web: /api/kernel/query

LMStudioClient:
  listModels(baseURL, apiKey)
  streamChat(baseURL, apiKey, modelID, temperature, context, messages)

LocalAIRuntimeConfigurationLoader:
  load(environment, bundle, fileManager)
  parseEnv(raw)
```

Regra de arquitetura:
- a aba IA não pode voltar a concentrar layout, prompt, networking e componentes no mesmo arquivo;
- o root só coordena estado e ações;
- prompt/contexto ficam em `Services`;
- chat e painéis ficam em views dedicadas;
- seleção lateral fica em `Models/LocalAISidePanel.swift`.

Tabela de decisão:

| Estado | UI |
| --- | --- |
| modo padrão | PocketKernel |
| servidor web remoto | browser chama `/api/kernel/query` no PocketWiki remoto |
| resposta Kernel com `missing_evidence=[]` | exibir resposta e metadados de governança |
| resposta Kernel com `missing_evidence` preenchido | exibir resposta governada sem esconder lacuna |
| PocketKernel offline | erro claro, conversa preservada |
| sem modelo | campo manual de model identifier |
| modelos encontrados | picker com modelos |
| modelo salvo inválido | usa `LM_STUDIO_MODEL` se estiver na lista, senão usa primeiro modelo de chat |
| LM Studio com auth | token vem de `.env`/ambiente ou campo manual em memória |
| resposta em andamento | botão cancelar e bolha assistant streaming |
| composer focado | `Enter` envia; `Shift+Enter` quebra linha |
| suspeita de alucinação | botão `Reset`, volta para `Auto`, temperatura `0.2` e limpa contexto anterior |
| painel lateral aberto | rail com `LM Studio` e `Contexto`, sem empilhar configuração acima da conversa |
| endpoint público | erro local, sem request |
| LM Studio offline | erro HTTP/conexão e conversa preservada |
| pergunta simples | conversa geral, sem carregar contexto pesado |
| pergunta sobre wiki | consulta seletiva por título, path, resumo, tags e headings, sempre com snapshot do índice |

Limites:
- endpoint padrão do PocketKernel é `http://127.0.0.1:8080`;
- endpoint informado como `http://127.0.0.1:8080` é normalizado para `/v1/kernel`;
- proxy web do servidor PocketWiki é `/api/kernel/query`;
- request PocketKernel usa JSON máximo aceito pelo servidor HTTP local;
- endpoint padrão é `http://127.0.0.1:1234/v1`;
- endpoint informado sem path, como `http://127.0.0.1:1234`, é normalizado automaticamente para `/v1`;
- hosts aceitos: `localhost`, `.local`, loopback, RFC1918 IPv4, link-local IPv4 e IPv6 local/link-local;
- token opcional fica em memória da sessão e não é persistido;
- `.env` só é lido para configuração runtime local e o token não é exibido em logs;
- contexto padrão limitado a 12.000 caracteres;
- máximo configurável nesta fase: 32.000 caracteres;
- conversa usa Chat Completions OpenAI-compatible, não WebView.
- streaming atualiza SwiftUI em lotes curtos, não token a token.

Regras de falha:
- se PocketKernel estiver indisponível, falhar com erro `pocketkernel_proxy_failed`/HTTP 502 no proxy web;
- se o Kernel retornar `missing_evidence`, não transformar isso em sucesso silencioso;
- se o usuário escolher LM Studio direto, deixar claro que o MCP não participa desse caminho;
- se não houver `modelID`, não enviar;
- se o endpoint não for local, falhar antes de montar request;
- se o streaming não emitir conteúdo, mostrar erro claro;
- cancelamento interrompe o task e remove estado `isStreaming`;
- histórico da conversa local não é escrito em arquivo.

## 2.4 — Entrega mínima

- aba `IA`;
- modo padrão PocketKernel;
- client HTTP para `/v1/kernel`;
- proxy web `/api/kernel/query`;
- configuração de endpoint/modelo no card lateral;
- contexto automático com card lateral de auditoria;
- busca de modelos;
- chat com streaming;
- cancelamento e limpeza de histórico;
- testes `AI-01` a `AI-09` passando em core;
- build e smoke do launcher passando.
