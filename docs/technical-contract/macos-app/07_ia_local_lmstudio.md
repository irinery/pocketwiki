# 07 — IA com LM Studio

## 2.1 — O que é

Tela e serviço para conversar com uma IA local via LM Studio usando endpoint OpenAI-compatible.

Responsabilidades explícitas:
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
- executar ferramentas ou MCPs;
- persistir token secreto.

## 2.2 — Testes obrigatórios

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

## 2.3 — Implementação

Estruturas:

```yaml
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
- se não houver `modelID`, não enviar;
- se o endpoint não for local, falhar antes de montar request;
- se o streaming não emitir conteúdo, mostrar erro claro;
- cancelamento interrompe o task e remove estado `isStreaming`;
- histórico da conversa local não é escrito em arquivo.

## 2.4 — Entrega mínima

- aba `IA`;
- configuração de endpoint/modelo no card lateral;
- contexto automático com card lateral de auditoria;
- busca de modelos;
- chat com streaming;
- cancelamento e limpeza de histórico;
- testes `AI-01` a `AI-09` passando em core;
- build e smoke do launcher passando.
