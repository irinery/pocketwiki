# RFC-0001 — Pocket Interop Contract

| Campo | Valor |
| --- | --- |
| Estado | Draft |
| Versão da RFC | 0.1.0 |
| Criada em | 2026-07-17 |
| Escopo | PocketWiki, PocketKernel, MiddlewareAuth, PocketTrace, PocketCli e futuras aplicações Pocket |
| Host de referência | PocketWiki |
| Schema | `pocket.app.manifest/v1` |
| MCP de referência | revisão `2025-11-25`, negociada em runtime |

## Resumo

Esta RFC define como aplicações da família Pocket se descobrem, declaram capacidades, iniciam comunicação, reportam saúde e falhas e preservam seus limites de segurança.

O PocketWiki atua como host, registro operacional e centralizador visual. Ele pode iniciar aplicações empacotadas como add-ons, mas não se torna proprietário do domínio, dos dados ou das credenciais delas. Aplicações externas continuam responsáveis pelo próprio processo, armazenamento e atualização; o PocketWiki apenas estabelece uma conexão autorizada e exibe seu estado.

O Model Context Protocol continua responsável por tools, resources, prompts e negociação das capacidades MCP. O Pocket Interop Contract adiciona a camada que o MCP não pretende resolver: distribuição, descoberta, confiança do binário, supervisão do processo, health checks, logs, pareamento e política de atualização.

## Linguagem normativa

Os termos `DEVE`, `NÃO DEVE`, `DEVERIA`, `NÃO DEVERIA` e `PODE` são normativos.

- `DEVE` e `NÃO DEVE` representam requisito obrigatório para conformidade.
- `DEVERIA` representa o comportamento recomendado; desvios precisam ser documentados.
- `PODE` representa comportamento opcional.

## Motivação

Hoje a stack já possui integrações úteis, mas cada uma descreve lifecycle, health, credenciais, logs e build de forma própria. MiddlewareAuth e PocketKernel já podem ser executados pelo PocketWiki, PocketTrace já envia soluções para a wiki e PocketCli já oferece contratos JSON operacionais. Sem um contrato comum, cada integração nova tende a duplicar supervisor, UI, tratamento de falhas e segurança.

A padronização precisa resolver simultaneamente:

- experiência integrada sem exigir start manual dos componentes internos;
- independência real entre repositórios e produtos;
- comunicação local e remota sem descoberta insegura;
- erros sempre visíveis para o usuário e rastreáveis em log;
- compatibilidade verificável antes de iniciar ou atualizar;
- adoção incremental, sem reescrever as APIs atuais de cada projeto.

## Objetivos

Esta RFC tem os seguintes objetivos:

1. Definir um manifesto comum para qualquer aplicação Pocket.
2. Separar add-ons gerenciados de integrações externas.
3. Criar um lifecycle observável e recuperável.
4. Definir discovery e pareamento seguros.
5. Padronizar o perfil MCP usado pela stack.
6. Preservar as APIs de domínio atuais.
7. Definir versionamento Major, Minor e Patch e o canal alpha atual.
8. Tornar atualização e compatibilidade verificáveis.
9. Permitir que futuros projetos entrem na família sem código específico espalhado pelo PocketWiki.

## Fora de escopo

Esta RFC não:

- transforma o PocketWiki em service mesh ou init system do computador;
- substitui a especificação MCP;
- cria uma API de domínio única para todos os projetos;
- permite que o PocketWiki leia stores privados de outro app;
- autoriza execução remota apenas porque um serviço foi descoberto;
- define sincronização distribuída de dados;
- exige interface gráfica ou linguagem de programação específica;
- torna o PocketWiki requisito para executar qualquer outro projeto.

## Terminologia

### Host Pocket

Aplicação que mantém o registro de integrações, apresenta status e pode supervisionar add-ons. O PocketWiki é o host de referência desta RFC.

### Aplicação Pocket

Produto independente que declara um manifesto `pocket.app.manifest/v1`.

### Add-on gerenciado

Executável empacotado, assinado e iniciado pelo host. Seu lifecycle pertence ao host apenas durante aquela execução integrada.

### Integração externa

Aplicação iniciada fora do host, na mesma máquina ou remotamente. O host não pode encerrar, atualizar ou reconfigurar seu processo sem um contrato adicional e consentimento explícito.

### Interface

Canal técnico declarado no manifesto, como `mcp`, `pocket-http` ou `cli-json`.

### Capacidade

Operação semântica oferecida ou consumida, independente do transporte. Exemplos: `wiki.evidence.read`, `kernel.query`, `auth.provider.manage`, `trace.solution.publish` e `ops.execution.plan`.

### Manifesto de pacote

Documento imutável incluído no artefato distribuído. Declara identidade, build, entrypoint, interfaces e permissões possíveis.

### Descritor de instância

Documento dinâmico servido por uma aplicação externa. Declara endpoints e capacidades efetivamente disponíveis naquela execução.

## Princípios

### Independência por padrão

Todo projeto DEVE compilar, testar, versionar e executar sem o PocketWiki. O modo integrado é adicional.

### Centralização sem apropriação

O PocketWiki PODE centralizar status, alertas e configuração de conexão. Ele NÃO DEVE assumir propriedade sobre dados, tokens, permissões ou decisões de domínio dos demais projetos.

### Capacidade antes de implementação

Consumidores DEVEM selecionar integrações por capacidade e versão, não pelo nome do executável ou pela estrutura interna do repositório.

### Confiança explícita

Descoberta informa existência; não concede confiança. Nenhuma aplicação descoberta em rede pode receber credenciais ou chamadas antes do pareamento.

### Falha visível

Falha operacional NÃO DEVE existir apenas em `stderr`. O host DEVE receber um evento estruturado, registrar o diagnóstico redigido e mostrar ação clara ao usuário quando houver impacto funcional.

### Menor privilégio

Cada conexão recebe somente scopes, roots, tools e credenciais necessários para as capacidades negociadas.

## Papéis atuais da stack

| Projeto | Papel principal | Forma recomendada | Limite de propriedade |
| --- | --- | --- | --- |
| PocketWiki | host, catálogo, conteúdo e MCP Evidence | standalone e host | wiki, UI, registro operacional e publicação local |
| PocketKernel | orquestração e governança de IA | add-on gerenciado ou serviço externo | harness, políticas, gateways e resposta governada |
| MiddlewareAuth | autenticação e providers | add-on gerenciado ou serviço externo | OAuth, API keys, perfis e refresh tokens |
| PocketTrace | captura, processamento e runbooks | app externo local; MCP/HTTP opcional | raw vault, revisão, redação e exportação |
| PocketCli | operação portátil e execução remota | integração externa CLI/MCP; nunca obrigatoriamente add-on | hosts, envelopes, aprovações, fleet e ledger operacional |

PocketTrace não deve virar add-on obrigatório porque possui app, permissões macOS e ciclo de revisão próprios. PocketCli não deve ser acoplado ao bundle macOS porque precisa continuar POSIX, leve e utilizável no iSH. Ambos podem publicar capacidades para o registro do PocketWiki.

## Classes de integração

### Classe A — add-on gerenciado

Usada para componentes internos distribuídos dentro do `PocketWiki.app`.

Requisitos:

- binário e manifesto incluídos no bundle;
- assinatura e SHA-256 validados antes da execução;
- bind somente em loopback quando houver HTTP;
- credenciais efêmeras ou store próprio isolado;
- stdout/stderr capturados conforme o transporte;
- encerramento gracioso junto com o host;
- atualização atômica junto com a release do host;
- ausência ou falha do add-on não pode impedir funções não relacionadas do PocketWiki.

Exemplos iniciais: PocketKernel e MiddlewareAuth.

### Classe B — aplicação externa local

Usada quando o processo roda na mesma máquina, mas foi iniciado e instalado independentemente.

Requisitos:

- endpoint ou comando configurado explicitamente;
- manifesto local ou descritor de instância validado;
- o PocketWiki pode observar e conectar, mas não encerrar o processo;
- atualização pertence à aplicação externa;
- caminhos customizados são marcados como não rastreados se não houver assinatura ou manifesto verificável;
- credencial de acesso fica no keychain ou no runtime seguro do host, nunca na URL.

Exemplos: PocketTrace instalado em `~/Applications` e uma instância standalone do MiddlewareAuth.

### Classe C — aplicação externa remota

Usada para serviços na LAN, tailnet ou internet.

Requisitos:

- endpoint configurado explicitamente ou descoberto e depois pareado;
- HTTPS obrigatório fora de loopback, salvo transporte privado aprovado explicitamente pelo usuário;
- autenticação com identidade e audience vinculadas ao serviço;
- health e readiness separados;
- o PocketWiki nunca controla o processo remoto implicitamente;
- atualização é informativa; o host não instala a nova versão;
- capacidades de escrita ou execução exigem consentimento e scopes próprios.

Exemplos: PocketCli Agent em um servidor e PocketKernel publicado por Tailscale Serve.

### Classe D — servidor MCP efêmero

Servidor MCP por stdio iniciado sob demanda por um cliente, sem endpoint HTTP permanente.

Requisitos:

- comando e argumentos representados como array, sem parsing por espaços;
- stdout exclusivo para JSON-RPC MCP;
- stderr reservado a log;
- diretórios roots explicitamente negociados;
- encerramento segue o lifecycle MCP de stdio;
- não aparece como serviço HTTP separado.

Exemplo: PocketWiki MCP Evidence iniciado pelo PocketKernel.

## Arquitetura de referência

```text
PocketWiki
  ├─ Pocket Integration Registry
  │    ├─ manifestos empacotados
  │    ├─ integrações configuradas
  │    └─ instâncias pareadas
  │
  ├─ Pocket Add-on Supervisor
  │    ├─ MiddlewareAuth [Classe A]
  │    └─ PocketKernel   [Classe A]
  │
  ├─ Pocket External Connector
  │    ├─ PocketTrace    [Classe B]
  │    └─ PocketCli      [Classe B/C]
  │
  └─ PocketWiki MCP Evidence [Classe D]
         ↑ stdio
      PocketKernel
```

O registro é o ponto de consulta da UI. Ele não é um proxy obrigatório para todo tráfego. Depois da negociação, componentes podem se comunicar diretamente quando a política permitir.

## Artefatos do contrato

### Manifesto de pacote

Nome canônico:

```text
pocket-app.json
```

Em um app macOS gerenciado:

```text
PocketWiki.app/
  Contents/
    Helpers/<executable>
    Resources/Addons/<AppID>/pocket-app.json
```

O manifesto DEVE passar no schema [`pocket-app-manifest.v1.schema.json`](schemas/pocket-app-manifest.v1.schema.json).

Exemplo reduzido:

```json
{
  "schema_version": "pocket.app.manifest/v1",
  "id": "dev.pocket.pocketkernel",
  "name": "PocketKernel",
  "version": "1.2.3",
  "release_channel": "alpha",
  "release_tag": "alpha-1.2.3",
  "distribution": {
    "class": "managed-addon",
    "update_strategy": "atomic-with-host"
  },
  "build": {
    "ref": "b0453b87ba06575bb5a8187b71e5baa07a843c36",
    "sha256": "<sha256-do-helper-distribuido>",
    "architectures": ["arm64", "x86_64"]
  },
  "runtime": {
    "executable": "pocketkernel",
    "arguments": ["-mode", "serve", "-addr", "${POCKET_BIND_ADDR}"],
    "ready_timeout_ms": 10000,
    "shutdown_timeout_ms": 5000
  },
  "interfaces": [
    {
      "id": "kernel-api",
      "protocol": "pocket-http",
      "role": "server",
      "version": "1.0",
      "endpoint": "http://127.0.0.1:${POCKET_PORT}/v1/kernel",
      "auth": "host-ephemeral-bearer"
    }
  ],
  "provides": ["kernel.query", "mcp.client"],
  "consumes": ["auth.provider.responses", "wiki.evidence.read"]
}
```

### Descritor de instância externa

Aplicações HTTP externas DEVERIAM publicar:

```http
GET /.well-known/pocket-app
```

Resposta mínima:

```json
{
  "schema_version": "pocket.app.instance/v1",
  "app_id": "dev.pocket.pockettrace",
  "manifest": "https://host.example/pocket-app.json",
  "instance_id": "01JZ...",
  "started_at": "2026-07-17T12:00:00Z",
  "endpoints": [
    {
      "interface_id": "mcp",
      "url": "https://host.example/mcp"
    }
  ],
  "status": "ready"
}
```

O descritor não pode conter secrets. Se o manifesto estiver embutido na resposta, ele ainda precisa obedecer ao schema e à política de confiança.

O descritor DEVE passar no schema [`pocket-app-instance.v1.schema.json`](schemas/pocket-app-instance.v1.schema.json).

### Registro no host

O PocketWiki mantém uma entrada por instância:

```json
{
  "app_id": "dev.pocket.pockettrace",
  "instance_id": "local-pockettrace",
  "mode": "external-local",
  "trust": "paired",
  "state": "ready",
  "capabilities": ["trace.search", "trace.solution.publish"],
  "last_seen_at": "2026-07-17T12:00:00Z"
}
```

Esse registro é operacional e pode ser reconstruído. Ele não substitui o store do aplicativo integrado.

## Versionamento

### Versão do produto

Cada produto usa SemVer estrito:

```text
MAJOR.MINOR.PATCH
```

- `MAJOR`: mudança incompatível no contrato público do produto.
- `MINOR`: capacidade nova compatível.
- `PATCH`: correção compatível.

Durante o canal atual:

```text
release_channel = alpha
release_tag     = alpha-MAJOR.MINOR.PATCH
version         = MAJOR.MINOR.PATCH
```

Quando o produto ficar estável:

```text
release_channel = stable
release_tag     = MAJOR.MINOR.PATCH
version         = MAJOR.MINOR.PATCH
```

A comparação de compatibilidade usa `version`; `release_channel` determina preferência e política de distribuição.

### Versão do contrato Pocket

O campo `schema_version` versiona a forma do documento. Mudanças incompatíveis criam `/v2`. Campos opcionais compatíveis podem ser adicionados ao `/v1`.

### Versão MCP

Nenhum manifesto deve assumir que a revisão MCP suportada pelo host será eterna. Cliente e servidor DEVEM negociar a revisão durante `initialize`. A RFC usa `2025-11-25` como baseline inicial, mas implementações PODEM suportar revisões posteriores e anteriores.

## Capacidades

Capacidades Pocket usam nomes estáveis no formato:

```text
<domínio>.<subdomínio opcional>.<ação>
```

Vocabulário inicial:

| Capacidade | Provedor inicial | Descrição |
| --- | --- | --- |
| `wiki.evidence.search` | PocketWiki | busca evidência na wiki |
| `wiki.evidence.read` | PocketWiki | lê documento autorizado |
| `wiki.solution.ingest` | PocketWiki | recebe solução revisada |
| `kernel.query` | PocketKernel | executa fluxo governado |
| `kernel.tools.route` | PocketKernel | roteia capability/tool |
| `auth.provider.login` | MiddlewareAuth | inicia autenticação de provider |
| `auth.provider.status` | MiddlewareAuth | consulta estado autenticado |
| `auth.provider.responses` | MiddlewareAuth | acessa provider sem expor credencial |
| `trace.session.search` | PocketTrace | busca sessões e runbooks revisados |
| `trace.solution.publish` | PocketTrace | publica solução aprovada |
| `ops.capabilities.read` | PocketCli | informa capacidades do host |
| `ops.execution.plan` | PocketCli | cria plano ou envelope |
| `ops.execution.run` | PocketCli | executa após política/aprovação |
| `ops.ledger.read` | PocketCli | consulta eventos operacionais |

O nome da capacidade não obriga um nome de tool MCP idêntico. O adapter registra o mapeamento entre capacidade, interface e operação concreta.

## Perfil MCP da Pocket Stack

### Transporte

- add-ons e servidores efêmeros DEVERIAM usar `stdio`;
- integrações externas DEVERIAM usar `Streamable HTTP`;
- novas integrações NÃO DEVERIAM implementar o transporte HTTP+SSE legado;
- transportes customizados precisam preservar JSON-RPC e lifecycle MCP e ser declarados no manifesto.

### Regras para stdio

- stdout contém apenas mensagens MCP válidas;
- logs usam stderr;
- command e arguments são campos separados;
- secrets podem ser entregues pelo ambiente ou descritor de arquivo seguro, nunca por argumento de linha de comando;
- o cliente fecha stdin, aguarda, envia `SIGTERM` e só depois `SIGKILL` conforme os timeouts declarados;
- um encerramento inesperado gera evento Pocket crítico mesmo que o protocolo MCP não tenha retornado erro.

### Regras para Streamable HTTP

- endpoint único, normalmente `/mcp`;
- validação obrigatória de `Origin` quando presente;
- bind local em loopback;
- HTTPS e autenticação para acesso remoto;
- suporte aos headers e à revisão negociada do protocolo;
- tokens precisam ter audience do servidor MCP e não podem ser repassados a APIs downstream.

### Negociação

O resultado de `initialize` é a fonte de verdade das capacidades MCP daquela sessão. O manifesto representa intenção e compatibilidade antes da conexão; ele não substitui a negociação MCP.

### Roots e acesso a arquivos

Roots DEVEM ser explícitos, mínimos e concedidos por sessão. Um add-on não herda automaticamente acesso à pasta completa da wiki ou aos arquivos do usuário.

### Tools com efeito

Tools de leitura podem ser liberadas conforme scopes. Tools que escrevem, executam comandos, alteram infraestrutura ou publicam dados DEVEM declarar impacto e política de aprovação. O contrato de envelopes do PocketCli continua sendo a autoridade para execução operacional.

## Discovery

### Add-ons empacotados

O host examina apenas diretórios internos conhecidos do próprio bundle. Não existe busca arbitrária no disco por executáveis com nomes parecidos.

### Integrações configuradas

O usuário pode informar endpoint, manifesto ou comando explicitamente. Overrides devem ficar visíveis na UI e ser marcados como externos.

### mDNS

Aplicações externas PODEM anunciar `_pocket-app._tcp`. O anúncio deve conter apenas:

```text
id=<app-id>
instance=<instance-id>
schema=pocket.app.instance/v1
path=/.well-known/pocket-app
```

mDNS serve somente para descoberta. O PocketWiki DEVE exigir pareamento antes de confiar ou transmitir credenciais.

### Tailscale e inventário

O PocketCli PODE fornecer candidatos encontrados no inventário Tailscale. Esses candidatos seguem a mesma exigência de pareamento. Estar na tailnet não equivale a autorização da aplicação.

## Pareamento e confiança

Estados de confiança:

| Estado | Significado |
| --- | --- |
| `bundled-verified` | binário dentro do bundle, assinatura e hash válidos |
| `paired` | identidade externa confirmada e credencial emitida |
| `configured-unverified` | endpoint configurado, mas identidade não verificável |
| `discovered` | anúncio encontrado, sem autorização |
| `revoked` | confiança removida |

Fluxo externo recomendado:

1. Descobrir ou informar o endpoint.
2. Buscar descritor sem enviar credenciais.
3. Validar TLS, identidade e `app_id`.
4. Mostrar capacidades e permissões solicitadas.
5. Usuário aprovar o pareamento.
6. Emitir ou obter credencial limitada por audience e scopes.
7. Executar health/readiness e negociação MCP.
8. Registrar a instância como `paired`.

Mudança de identidade, certificado, `app_id` ou audience invalida o pareamento.

## Autenticação e secrets

### Add-on gerenciado

O host PODE gerar bearer efêmero por processo. Secrets persistentes continuam no componente que é dono deles. MiddlewareAuth permanece responsável por tokens OAuth e API keys de providers.

Secrets:

- não podem aparecer em argumentos;
- não podem aparecer em manifesto, descritor, log ou evento;
- devem ser redigidos de mensagens de erro;
- devem usar arquivo `0600`, keychain ou ambiente herdado conforme a plataforma;
- devem ser rotacionáveis sem invalidar stores criptografados não relacionados.

### MCP stdio

A autorização MCP HTTP não se aplica ao stdio. Credenciais locais são fornecidas pelo ambiente seguro do processo, conforme recomendado pelo próprio MCP.

### MCP remoto

Servidores MCP HTTP protegidos DEVERIAM seguir o fluxo de autorização MCP baseado em OAuth 2.1. O token recebido pelo MCP server deve ter audience específica e NÃO DEVE ser repassado ao provider ou API downstream.

### APIs Pocket HTTP

APIs de domínio que não são MCP podem usar bearer emitido pelo host ou pelo MiddlewareAuth. Cada token deve conter ou estar associado a:

- emissor;
- audience;
- scopes;
- expiração curta;
- instance ou session ID quando aplicável.

## Lifecycle do add-on

Estados normativos:

```text
discovered
  -> validating
  -> starting
  -> ready
  -> degraded
  -> stopping
  -> stopped

qualquer estado operacional
  -> failed
```

### `validating`

O host valida schema, compatibilidade, executável, assinatura, hash e permissões necessárias.

### `starting`

O processo foi criado, mas readiness ainda não foi confirmada. PID não equivale a serviço funcional.

### `ready`

Health, readiness, autenticação mínima e capacidades obrigatórias foram confirmadas.

### `degraded`

O processo responde, mas uma capacidade opcional ou dependência não está disponível. A UI deve informar qual capacidade foi afetada.

### `failed`

O processo não iniciou, caiu, violou integridade ou falhou em uma capacidade obrigatória. O host registra evento e apresenta alerta conforme severidade.

### Política de restart

O manifesto pode declarar:

```json
{
  "restart": {
    "policy": "on-failure",
    "max_attempts": 3,
    "window_seconds": 60,
    "backoff_seconds": [1, 5, 15]
  }
}
```

Depois do limite, o host DEVE parar tentativas automáticas, manter o estado `failed` e oferecer ação manual. Crash loop não pode ficar silencioso.

## Health e readiness

`health` responde se o processo está vivo e seu runtime básico funciona. `readiness` responde se ele está apto a oferecer as capacidades obrigatórias.

Uma integração HTTP DEVERIA oferecer:

```text
GET /healthz
GET /readyz
GET /.well-known/pocket-app
```

O manifesto também pode declarar uma sonda específica já existente, como o `405 Method Not Allowed` esperado no `GET /v1/kernel`. Adapters legados podem usar essa sonda durante a migração.

O PocketWiki NÃO DEVE exibir verde apenas porque a porta está aberta. Credencial, interface e capacidades obrigatórias precisam ser validadas separadamente.

## Eventos, erros e logs

Formato canônico:

```json
{
  "schema_version": "pocket.event/v1",
  "event_id": "01JZ...",
  "timestamp": "2026-07-17T12:00:00Z",
  "source": {
    "app_id": "dev.pocket.pocketkernel",
    "instance_id": "managed-1234"
  },
  "severity": "error",
  "code": "addon.process.exited",
  "message": "PocketKernel encerrou inesperadamente.",
  "correlation_id": "req-123",
  "user_action": "Reiniciar o add-on e abrir os logs.",
  "details": {
    "exit_code": 15
  }
}
```

O evento DEVE passar no schema [`pocket-event.v1.schema.json`](schemas/pocket-event.v1.schema.json).

Severidades:

| Severidade | UI | Log |
| --- | --- | --- |
| `debug` | oculto por padrão | opcional |
| `info` | status | obrigatório para transições relevantes |
| `warning` | card/aviso não modal | obrigatório |
| `error` | card e modal quando há impacto imediato | obrigatório |
| `critical` | modal global e ação explícita | obrigatório |

Regras:

- toda falha de start ou queda inesperada gera `error` ou `critical`;
- mensagens mostradas ao usuário não podem conter secrets;
- detalhes técnicos completos ficam no log persistente do componente;
- eventos do host usam timestamp UTC e `correlation_id` quando relacionados a uma requisição;
- clicar em “Abrir logs” deve levar ao evento correspondente;
- o registro continua disponível depois que a modal for fechada.

## Atualizações

### Add-on gerenciado

O add-on não se atualiza sozinho dentro do PocketWiki. A release do host é a unidade atômica:

```text
PocketWiki.app
  + PocketKernel
  + MiddlewareAuth
  + manifestos
  + hashes pós-assinatura
```

Antes de instalar, o updater DEVE validar:

1. assinatura do pacote;
2. manifesto da release;
3. presença dos helpers obrigatórios;
4. manifesto interno de cada helper;
5. SHA-256 do binário distribuído;
6. igualdade entre manifesto público e interno;
7. compatibilidade com o host.

Se qualquer verificação falhar, a atualização inteira é recusada. Depois da substituição do app, processos antigos são encerrados e a nova versão inicia os helpers novos.

### Aplicação externa

A aplicação externa mantém sua estratégia de atualização. O manifesto pode publicar `update.check_url`, mas o PocketWiki apenas informa disponibilidade. Instalação remota ou atualização do outro app exige contrato separado e ação explícita do usuário.

### Compatibilidade

O manifesto pode declarar:

```json
{
  "compatibility": {
    "host": ">=0.2.0 <1.0.0",
    "pocket_contract": "1.x",
    "mcp_protocols": ["2025-11-25"]
  }
}
```

Versão incompatível é erro de validação, não tentativa de execução seguida por crash.

## Permissões e aprovação

Permissões são declaradas antes do start ou pareamento:

```json
{
  "permissions": [
    {
      "id": "wiki.read",
      "required": true,
      "reason": "Buscar evidências solicitadas pelo usuário."
    },
    {
      "id": "ops.execute",
      "required": false,
      "approval": "per-operation",
      "reason": "Executar plano previamente revisado."
    }
  ]
}
```

Uma capability declarada não concede sua permissão automaticamente. O registro combina:

```text
capacidade oferecida
  + compatibilidade
  + confiança
  + scope concedido
  + aprovação quando necessária
  = operação disponível
```

## Comportamento por projeto

### PocketWiki

DEVE implementar o registro, supervisor, conectores externos e UI de status. Continua dono da wiki e do MCP Evidence. Não armazena credenciais de provider.

### PocketKernel

DEVE declarar `kernel.query` e suas dependências. Como add-on, recebe endpoints e bearer efêmero do host. Como externo, publica health/readiness e pode usar Streamable HTTP para capacidades MCP futuras. Continua sendo o harness obrigatório da IA governada.

### MiddlewareAuth

DEVE declarar capacidades de provider e manter credenciais em seu próprio store. Pode operar como add-on ou externo. Não entrega refresh token ou API key a consumidores. Em uma futura interface MCP remota, deve seguir autorização MCP HTTP; sua API HTTP atual continua válida durante a migração.

### PocketTrace

DEVERIA começar como aplicação externa local. Pode expor resources MCP somente de bundles revisados e redigidos. Raw vault e evidência visual sensível não ficam acessíveis por padrão. Publicação no PocketWiki continua exigindo a regra de revisão e ETag já existente.

### PocketCli

DEVERIA expor seu contrato JSON atual por adapter CLI/MCP, preservando compatibilidade POSIX. Leitura de capabilities e ledger pode ser scope separado. Execução usa plan/envelope/approval; o PocketWiki não contorna a aprovação do PocketCli. Agentes remotos entram como Classe C.

## Migração

### Fase 0 — contrato e fixtures

- aceitar esta RFC;
- estabilizar schema e exemplos;
- criar validador de manifesto;
- definir suite de conformidade.

### Fase 1 — supervisor genérico no PocketWiki

- extrair lógica comum de `MiddlewareAuthAddonManager` e `PocketKernelAddonManager`;
- manter adapters específicos apenas para sondas e configuração de domínio;
- gerar o registro único da aba Servidor;
- preservar o comportamento atual durante a migração.

### Fase 2 — manifestos nativos

- MiddlewareAuth e PocketKernel passam a publicar `pocket-app.json` em suas releases;
- o builder do PocketWiki consome os manifestos sem reconstruir metadados de domínio;
- CI valida schema, hash pós-assinatura e compatibilidade.

### Fase 3 — externos

- PocketTrace publica descritor local e capabilities de conteúdo revisado;
- PocketCli ganha adapter MCP/CLI baseado nos JSON já existentes;
- PocketWiki implementa pareamento, trust store e mDNS opcional.

### Fase 4 — distribuição compartilhada

- mover schema, fixtures e suite para um repositório canônico `PocketContracts`;
- versionar SDKs mínimos apenas onde reduzem duplicação;
- manter compatibilidade por contrato, sem dependência de código-fonte entre projetos.

## Conformidade e testes

Uma aplicação compatível deve passar:

1. validação JSON Schema;
2. teste de versão SemVer e release tag;
3. teste de manifesto sem secrets;
4. teste de health e readiness;
5. teste de negociação das interfaces declaradas;
6. teste de timeout;
7. teste de shutdown gracioso;
8. teste de queda inesperada com evento visível;
9. teste de redaction de logs;
10. teste de identidade e scopes externos;
11. teste de incompatibilidade sem iniciar processo;
12. teste de update adulterado para add-ons gerenciados.

Os schemas e fixtures desta RFC podem ser validados com:

```sh
./script/validate_pocket_interop_contract.sh
```

O host compatível deve demonstrar:

- um add-on saudável;
- um add-on ausente;
- um add-on com hash inválido;
- crash loop interrompido;
- externo descoberto mas não pareado;
- externo pareado e pronto;
- externo com certificado ou identidade alterada;
- capability opcional degradada;
- evento crítico persistido depois da modal;
- atualização atômica com dois ou mais add-ons.

## Segurança

### Ameaças consideradas

- binário substituído depois do build;
- serviço malicioso anunciando o mesmo nome via mDNS;
- DNS rebinding contra MCP local HTTP;
- token vazado em argumento, URL ou log;
- token de um serviço reutilizado em outro;
- host agindo como confused deputy;
- tool de execução liberada como leitura;
- path traversal em roots ou artefatos;
- processo em crash loop consumindo recursos;
- atualização parcial entre host e add-on.

### Controles mínimos

- assinatura, hash e manifesto para add-ons;
- loopback por padrão;
- validação de Origin no Streamable HTTP;
- OAuth/audience para MCP remoto;
- tokens efêmeros e sem passthrough;
- roots mínimos;
- scopes e aprovação por impacto;
- logs redigidos;
- pareamento externo explícito;
- atualização atômica.

## Decisões registradas

1. PocketWiki é o host de referência, não o proprietário da stack.
2. MCP não será estendido para carregar lifecycle de processos; o Pocket Interop Contract é uma camada complementar.
3. PocketKernel e MiddlewareAuth são os primeiros add-ons gerenciados.
4. PocketTrace e PocketCli começam como integrações externas.
5. Discovery remoto nunca implica autorização.
6. O canal atual usa `alpha-x.y.z`; o estável usará `x.y.z`.
7. Updates de add-ons internos são atômicos com o PocketWiki.
8. APIs de domínio existentes continuam válidas e são mapeadas para capabilities.

## Questões abertas

Antes de mover a RFC para `accepted`, ainda é necessário decidir:

- se o trust store externo fica no Keychain ou em arquivo assinado pelo host;
- se o descritor de instância terá assinatura própria além de TLS;
- qual sintaxe de range SemVer será adotada pelos validadores Swift, Go e shell;
- se o host suportará múltiplas instâncias do mesmo `app_id` na primeira versão;
- se mDNS entra na primeira implementação ou somente após pareamento explícito por URL;
- quais capabilities do PocketTrace podem ser expostas sem abrir material visual sensível;
- se o adapter PocketCli MCP roda no host remoto ou como proxy local sobre SSH.

## Critério para aceitar a RFC

A RFC pode mudar de `draft` para `accepted` quando:

- schema e quatro exemplos forem aprovados;
- PocketKernel e MiddlewareAuth iniciarem pelo supervisor genérico;
- falha e atualização continuarem cobertas por testes reais;
- ao menos um externo completar discovery, pareamento, readiness e revogação;
- nenhuma credencial de provider atravessar o limite MiddlewareAuth;
- PocketTrace e PocketCli confirmarem que os contratos não quebram execução standalone.

## Referências

- [MCP Architecture](https://modelcontextprotocol.io/specification/2025-11-25/architecture)
- [MCP Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- [MCP Versioning](https://modelcontextprotocol.io/docs/learn/versioning)
- [Add-on MiddlewareAuth](../technical-contract/macos-app/09_middleware_auth_addon.md)
- [Add-on PocketKernel](../technical-contract/macos-app/10_pocketkernel_addon.md)
- [PocketTrace → PocketWiki](../technical-contract/pockettrace/01_contrato_api_ingestao_solutions.md)
