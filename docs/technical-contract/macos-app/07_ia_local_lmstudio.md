# 07 — IA via PocketKernel Harness e MiddlewareAuth

## 2.1 — O que é

Tela e serviço para conversar com IA sem bypass do harness. O PocketWiki exibe um painel compacto de provider/modelo/raciocínio, guarda detalhes técnicos em diálogo avançado, configura OpenAI ou LM Studio no MiddlewareAuth quando necessário e envia toda pergunta para o PocketKernel.

Fluxo obrigatório:

```text
PocketWiki UI/app ou browser
  -> MiddlewareAuth /v1/projects/{projectId}/auth/{openai|lmstudio}/...
  -> PocketKernel /v1/kernel
  -> PocketKernel chama PocketWiki MCP via stdio
  -> PocketWiki MCP devolve evidência
  -> PocketKernel chama provider configurado
  -> PocketKernel monta resposta governada
```

Regra crítica: PocketWiki não chama LM Studio, ChatGPT ou MiddlewareAuth para gerar resposta final. MiddlewareAuth é dono de autenticação/configuração de provider; PocketKernel é o harness obrigatório para a resposta.

Responsabilidades explícitas:

- chamar `POST /v1/kernel` ou `/api/kernel/query` com `{ text, channel, app_id, user_id }`;
- usar `app_id=pocketwiki`;
- usar `user_id` alinhado ao `profileId` escolhido na UI quando aplicável;
- iniciar login/status OpenAI no MiddlewareAuth;
- registrar LM Studio no MiddlewareAuth com `projectId`, `profileId`, `baseUrl` e `apiKey`;
- expor `POCKETKERNEL_BASE_URL`, default `http://127.0.0.1:8080`;
- expor `MIDDLEWARE_BASE_URL`, default `http://127.0.0.1:18787`;
- expor `MIDDLEWARE_CLIENT_TOKEN` apenas no processo local/servidor, nunca no `/api/config`;
- manter modelo como string livre, porque o contrato MiddlewareAuth aceita modelo provider-specific;
- remover `/api/ai/chat`, `/api/ai/models` e qualquer chamada direta a `/chat/completions` no PocketWiki.

Não é responsabilidade deste componente:

- persistir API key do LM Studio no PocketWiki;
- listar modelos chamando LM Studio direto;
- autenticar OpenAI/Codex diretamente fora do MiddlewareAuth;
- executar MCPs direto na UI;
- substituir contratos do MiddlewareAuth.

## 2.2 — Testes obrigatórios

TESTE AI-00
dado:    aba IA no estado padrão
quando:  o usuário envia pergunta
então:   o request sai para PocketKernel `/v1/kernel` ou `/api/kernel/query`

TESTE AI-01
dado:    prompt enviado pela UI macOS
quando:  o app monta o payload
então:   `app_id=pocketwiki`, `channel=api` e `user_id` não vazio são enviados ao Kernel

TESTE AI-02
dado:    prompt enviado pelo cockpit web
quando:  o browser está servido pelo PocketWiki
então:   o request usa `/api/kernel/query`, não provider direto

TESTE AI-03
dado:    LM Studio base URL e API key preenchidos
quando:  o usuário clica `Configurar LM Studio`
então:   o PocketWiki chama MiddlewareAuth em `/v1/projects/{projectId}/auth/lmstudio/api-key`

TESTE AI-04
dado:    `MIDDLEWARE_CLIENT_TOKEN` ausente no servidor
quando:  o browser tenta configurar LM Studio via proxy
então:   o servidor responde erro claro `middlewareauth_token_missing`

TESTE AI-05
dado:    API key do LM Studio vazia
quando:  o usuário consulta status
então:   o PocketWiki chama `/auth/lmstudio/status?profileId=...`

TESTE AI-05A
dado:    método OpenAI selecionado
quando:  o usuário clica `Login`
então:   o PocketWiki chama MiddlewareAuth em `/v1/projects/{projectId}/auth/openai/login`

TESTE AI-05B
dado:    método OpenAI selecionado
quando:  o usuário clica atualizar status
então:   o PocketWiki chama MiddlewareAuth em `/v1/projects/{projectId}/auth/openai/status?profileId=...`

TESTE AI-06
dado:    endpoint MiddlewareAuth fora de localhost, `.local`, IP privado ou Tailscale
quando:  o usuário tenta configurar provider
então:   o cliente rejeita antes de enviar segredo

TESTE AI-07
dado:    PocketKernel configurado com `POCKETKERNEL_WIKI_MCP_COMMAND=node` e `POCKETKERNEL_WIKI_MCP_ARGS=".../pocketwiki-mcp-server.mjs --root /wiki"`
quando:  a UI envia pergunta operacional
então:   a resposta governada indica `profile_used=wiki` e `missing_evidence=[]` quando há evidência confiável

TESTE AI-08
dado:    MCP indisponível ou sem documento confiável
quando:  a UI envia pergunta que exige status operacional
então:   a resposta do Kernel preserva `missing_evidence`, incluindo `contexto_requerido_indisponivel` ou `fonte_confiavel_de_status_operacional`

TESTE AI-09
dado:    busca textual no repo
quando:  validamos rotas/código da UI
então:   não existem `/api/ai/chat`, `/api/ai/models`, `LM Studio direto` nem chamada direta a `/chat/completions`

## 2.3 — Implementação

Estruturas:

```yaml
LocalAIView:
  responsabilidade: coordenar estado, preferências, bootstrap runtime e ações
  envia_prompt_por: LocalAIChatSession.sendViaPocketKernel

LocalAISidePanelContent:
  responsabilidade: card IA e card Contexto
  campos:
    - método OpenAI ou LM Studio
    - modelo livre
    - raciocínio baixo, médio ou alto
    - botões Login/Configurar, atualizar status e configurações avançadas

LocalAIAdvancedSettingsSheet:
  responsabilidade: esconder detalhes técnicos do card principal
  campos:
    - PocketKernel base URL
    - MiddlewareAuth base URL
    - projectId
    - profileId/userId
    - Middleware token em memória quando não vier do runtime
    - LM Studio base URL
    - LM Studio API key em memória

LocalAIChatSession:
  refreshProviderStatus(...)
  startOpenAILogin(...)
  configureLMStudioProvider(...)
  sendViaPocketKernel(...)

MiddlewareAuthClient:
  openAIStatus(...)
  startOpenAILogin(...)
  configureLMStudio(...)
  lmStudioStatus(...)
  endpoint_default: http://127.0.0.1:18787

PocketKernelClient:
  query(baseURL, text, channel, appID, userID)
  endpoint_default: http://127.0.0.1:8080/v1/kernel
  proxy_web: /api/kernel/query

PocketWikiHTTPServer:
  POST /api/kernel/query
  POST /api/middleware/openai/login
  POST /api/middleware/openai/status
  POST /api/middleware/lmstudio/api-key
  POST /api/middleware/lmstudio/status
```

Tabela de decisão:

| Estado | Comportamento |
| --- | --- |
| pergunta enviada | sempre PocketKernel |
| provider OpenAI selecionado | login/status via MiddlewareAuth |
| provider LM Studio configurado | registrar no MiddlewareAuth |
| API key vazia | consultar status no MiddlewareAuth |
| MiddlewareAuth sem token | erro explícito, sem fallback direto |
| PocketKernel offline | erro explícito, conversa preservada |
| resposta Kernel com `missing_evidence=[]` | exibir resposta e metadados |
| resposta Kernel com `missing_evidence` preenchido | exibir lacuna sem esconder |
| modelo vazio | permitir string livre, sem bloquear harness |
| endpoint público | rejeitar antes de enviar segredo |

Limites:

- PocketKernel default: `http://127.0.0.1:8080`;
- MiddlewareAuth default: `http://127.0.0.1:18787`;
- LM Studio default: `http://127.0.0.1:1234`;
- projectId default: `acme`;
- profileId default: `default`;
- hosts aceitos: `localhost`, `.local`, loopback, RFC1918 IPv4, link-local IPv4, Tailscale IPv4 e IPv6 local/link-local;
- API key do LM Studio fica só em memória da sessão do PocketWiki;
- `MIDDLEWARE_CLIENT_TOKEN` pode vir de ambiente/.env do PocketWiki ou campo temporário no app macOS;
- browser remoto usa proxy do PocketWiki e não recebe `MIDDLEWARE_CLIENT_TOKEN`.

Regras de falha:

- se MiddlewareAuth estiver indisponível, falhar com `middlewareauth_proxy_failed`;
- se token do MiddlewareAuth faltar, falhar com `middlewareauth_token_missing`;
- se login OpenAI falhar, falhar explicitamente no painel sem cair para provider direto;
- se API key do LM Studio faltar para registro, falhar com `lmstudio_api_key_missing`;
- se PocketKernel estiver indisponível, falhar com `pocketkernel_proxy_failed`;
- se o Kernel retornar `missing_evidence`, não transformar em sucesso silencioso;
- histórico da conversa local não é escrito em arquivo.

## 2.4 — Entrega mínima

- aba `IA` compacta, sem formulário inline de infraestrutura;
- seletor de método `OpenAI`/`LM Studio`, modelo e raciocínio;
- diálogo avançado para PocketKernel, MiddlewareAuth, projectId, profileId, LM Studio URL e API key;
- client HTTP para `/v1/kernel`;
- proxy web `/api/kernel/query`;
- client/proxy MiddlewareAuth para OpenAI login/status e LM Studio status/API key;
- card lateral de contexto;
- cancelamento e limpeza de histórico;
- docs atualizados;
- build Swift e checks Node/MCP passando.
