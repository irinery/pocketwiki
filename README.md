<p align="center">
  <img src="assets/favicon.png" alt="PocketWiki" width="500">
</p>
Funcionalidades:
- Le Markdown, `.excalidraw` e `.excalidraw.md` direto do filesystem local;
- Exibe a base como wiki interativa com leitor, dashboard, mapa, saude, tempo e IA;
- Usa layout responsivo para celular, tablet, notebook e telas grandes;
- Usa icones compactos nas areas principais para reduzir ruido em telas pequenas;
- Usa IA via PocketKernel Harness, com provider OpenAI ou LM Studio configurado pelo MiddlewareAuth;
- Interpreta desenhos Excalidraw como fontes visuais pesquisaveis e indexaveis.

## Base de referencia

A base fixa compartilhada fica configurada no `.env`:

```sh
POCKETWIKI_REFERENCE_PATH="/absolute/path/to/reference/wiki"
POCKETWIKI_REFERENCE_READONLY=true
```

O contrato local fica em `SKILL/connection.md`.

Existem duas formas de carregar a base:

- Base fixa no servidor: configure `POCKETWIKI_REFERENCE_PATH` no `.env`. Essa é a opção para celular/outros PCs na mesma rede, porque todos leem a wiki direto da máquina principal.
- Abertura manual: use `Abrir pasta`/`Fallback` no navegador. Nesse caso o handle fica no IndexedDB daquele navegador/dispositivo e serve como modo local/ad-hoc.

Quando rodar pelo `server.mjs` e o path do `.env` existir, ele tem prioridade como fonte compartilhada.

As APIs `/api/config` e `/api/wiki/files` releem essa configuracao durante a execucao, entao ajustes no `POCKETWIKI_REFERENCE_PATH` passam a refletir no proximo reload da pagina. O path aceita absoluto, relativo ao projeto, `~/...`, `$HOME/...`, `file://...` e espacos escapados copiados do terminal.

## Ingestão de soluções do PocketTrace

O endpoint `PUT /api/v1/solutions/{solution_id}` grava documentos revisados pelo PocketTrace em `solutions/{solution_id}.md`. A revisão remota é o SHA-256 dos bytes persistidos, então qualquer edição manual muda o `ETag` e força nova confirmação antes de overwrite.

Habilite escrita explicitamente:

```sh
POCKETWIKI_REFERENCE_READONLY=false
POCKETWIKI_WRITE_TOKEN="<segredo-longo-aleatorio>"
```

Sem token, a escrita falha fechada com `503`. Em modo read-only retorna `403`. O token não aparece em `/api/config`, `/api/routes`, logs ou metadados. O limite padrão é 8 MiB e pode ser aumentado com `POCKETWIKI_WRITE_MAX_BYTES`; valores menores são ignorados.

Criação:

```sh
curl --fail-with-body \
  -X PUT \
  -H "Authorization: Bearer $POCKETWIKI_WRITE_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H 'Idempotency-Key: solution_demo:doc_v1' \
  --data-binary @solution.json \
  https://pocketwiki.example/api/v1/solutions/solution_demo
```

Atualização condicional:

```sh
curl --fail-with-body \
  -X PUT \
  -H "Authorization: Bearer $POCKETWIKI_WRITE_TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H 'Idempotency-Key: solution_demo:doc_v2' \
  -H 'If-Match: "sha256:REVISAO_OBSERVADA"' \
  --data-binary @solution-v2.json \
  https://pocketwiki.example/api/v1/solutions/solution_demo
```

Use HTTPS no cliente, normalmente com Tailscale Serve ou reverse proxy apontando para o servidor local. O contrato completo está em `docs/technical-contract/pockettrace/01_contrato_api_ingestao_solutions.md`.

## Excalidraw

Arquivos `.excalidraw`, `.excalidraw.md` e Markdown gerado pelo plugin Obsidian Excalidraw entram como fontes da wiki. Ao abrir uma pagina desse tipo, a UI prioriza a aba Excalidraw; o botao `Abrir indice` força a leitura textual quando precisar ver o markdown bruto.

O fluxo atual:

- detecta cenas JSON puras de `.excalidraw`
- descompacta blocos `## Drawing` com fence `compressed-json` usando LZString
- interpreta fences `json` quando o Obsidian grava a cena sem compressao
- renderiza a cena completa em SVG com `@excalidraw/utils` (`exportToSvg`)
- no app macOS, abre um editor Excalidraw completo via `WKWebView` usando `@excalidraw/excalidraw`
- salva alterações direto na wiki local com botao Salvar, `Cmd+S` e autosave; fontes remotas ficam em modo somente leitura
- usa fallback textual quando so existem `Text Elements` disponiveis
- mostra se a visualizacao veio de `cena completa` ou `fallback textual`
- extrai textos, links, tags e relacoes por setas/bindings para busca, mapa, saude e contexto da IA

O renderer oficial web e o editor desktop ficam empacotados localmente e so carregam quando a aba Excalidraw e aberta. Para gerar ou atualizar os bundles:

```sh
npm run build:excalidraw
```

Esse comando atualiza `assets/excalidraw-renderer.js`, `assets/lz-string.min.js` e `Sources/PocketWikiMac/Resources/ExcalidrawEditor/`. Rode depois de `npm install` ou quando mexer em `src/excalidraw-renderer.js` ou `src/excalidraw-desktop/`.

O servidor tambem serve `.excalidraw` com content-type `application/vnd.excalidraw+json`, entao esses arquivos entram no mesmo fluxo de leitura, busca e indexacao dos Markdown.

## UI responsiva e atalho

A interface foi ajustada para funcionar de iPhone 13 ate ultrawide. Em telas menores, a navegacao usa botoes compactos por icone e textos reduzidos para evitar sobreposicao.

`manifest.webmanifest`, `sw.js` e `offline.html` formam a casca instalavel do PocketWiki. Se um atalho abrir enquanto o servidor local estiver indisponivel, a tela `offline.html` mostra um erro visual com acoes de retentar e copiar URL.

Esse cache e apenas da casca do app. A base compartilhada da wiki continua sendo o `POCKETWIKI_REFERENCE_PATH` no `.env`; APIs e conteudo indexado nao sao tratados como fonte persistente pelo service worker.

Para trocar o icone da sidebar depois, adicione `assets/favicon.png` ou `favicon.ico` na raiz do projeto. Sem arquivo, a UI cai no fallback `PW`.

## Setup local

Primeira instalacao ou atualizacao de dependencias:

```sh
npm install
npm run build:excalidraw
```

## Build macOS e assinatura

A versao desktop macOS fica disponivel em `.dmg` nas [releases do GitHub](https://github.com/irinery/pocketwiki/releases/latest).

Para gerar e abrir o app local:

```sh
./script/build_and_run.sh --verify
```

Para gerar o instalador localmente:

```sh
./script/build_macos_dmg.sh
```

O arquivo sai em `dist/release/PocketWiki-<versao>-macOS-universal.dmg`, junto com o `.sha256`. Para publicar uma release baixavel no GitHub, crie e envie uma tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

O build local usa a mesma política do PocketTrace:

```sh
cp .env.example .env.local
```

Configure apenas localmente:

```sh
POCKETWIKI_SIGN_MODE="auto"
POCKETWIKI_SIGNING_IDENTITY=""
POCKETWIKI_SKIP_SECRET_SCAN="0"
```

`auto` procura uma identidade `Apple Development` ou `Developer ID Application` no Keychain e assina o bundle sem imprimir nome, e-mail ou Team ID. Para fixar, use o hash do certificado em `POCKETWIKI_SIGNING_IDENTITY`, nunca a identidade completa. Para build sem conta Apple:

```sh
POCKETWIKI_SIGN_MODE=adhoc ./script/build_and_run.sh --verify
```

Antes do build, `script/scan_secrets.sh` bloqueia `.env` versionado, certificados/profiles versionados e padrões comuns de developer account no código. Não versionar `.env.local`, `.p8`, `.p12`, `.cer`, `.pem`, `.key`, `.mobileprovision`, `.provisionprofile` ou `.xcarchive`.

Para permitir assinatura pela automação do GitHub, coloque o certificado apenas em `Settings > Secrets and variables > Actions`, nunca no repositório:

- `APPLE_CODESIGN_CERTIFICATE_BASE64`: `.p12` exportado e codificado em base64.
- `APPLE_CODESIGN_CERTIFICATE_PASSWORD`: senha do `.p12`.
- `APPLE_CODESIGN_IDENTITY`: opcional, hash do certificado. Não use nome, e-mail ou Team ID.

Exporte o certificado localmente e copie só o base64 para o secret:

```sh
security export \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -o /tmp/pocketwiki-codesign.p12
base64 -i /tmp/pocketwiki-codesign.p12 | pbcopy
rm -f /tmp/pocketwiki-codesign.p12
```

No workflow `.github/workflows/macos-release.yml`, se `APPLE_CODESIGN_CERTIFICATE_BASE64` existir, a automação cria um keychain temporário no runner, importa o `.p12`, define `POCKETWIKI_SIGN_MODE=auto` e roda `./script/build_macos_dmg.sh`. Se o certificado não estiver configurado, o workflow cai para `POCKETWIKI_SIGN_MODE=adhoc`.

Para reduzir o raio de impacto, use environment protection no GitHub: crie um environment `release`, restrinja quem pode aprovar execução manual/tag, mova esses secrets para o environment e adicione `environment: release` no job `dmg` do workflow.

## Rodar no PC

O PocketWiki precisa ficar servido no PC. Deixe este comando rodando no terminal:

```sh
npm start
```

No próprio PC:

```text
http://localhost
```

Na LAN:

```text
http://pocketwiki.local
http://pokectwiki.local
```

Rotas detectadas pelo app:

```sh
curl http://localhost/api/routes
```

O boot do server tambem imprime URLs locais, LAN e Tailscale quando encontrar IP `100.x`.

O server binda em `0.0.0.0` e anuncia nomes `.local` via mDNS:

```sh
POCKETWIKI_BIND_HOST="0.0.0.0"
POCKETWIKI_PUBLIC_HOSTS="pocketwiki.local,pokectwiki.local"
POCKETWIKI_MDNS=true
```

Ao subir, o terminal imprime também URLs por IP, por exemplo:

```text
PocketWiki LAN IP: http://192.168.x.x
```

No celular, teste primeiro pelo IP. Se o IP funcionar e `.local` não, o problema é resolução mDNS da rede/cliente.

Checklist se o celular não acessar:

- PC e celular precisam estar na mesma rede/VLAN.
- No macOS, libere conexões de entrada para `node` em System Settings -> Network -> Firewall.
- Se tiver rede guest, mesh com isolamento/AP isolation ou VLAN IoT, o celular pode não alcançar o PC.
- Se `.local` falhar, use `http://IP_DO_PC` ou crie entrada DNS/hosts no roteador.
- A porta usada para URL sem porta é `80`. Se voltar para `8787`, a URL volta a precisar de `:8787`.

### Acessar sem porta

Browser so omite porta quando o servico esta em HTTP `80` ou HTTPS `443`. Registro mDNS/SRV nao faz Chrome/Safari abrirem `http://pocketwiki.local` em `8787` automaticamente.

Para LAN local sem porta:

```sh
npm start
```

O `.env` deve ter:

```sh
POCKETWIKI_PORT=80
```

Depois acesse:

```text
http://pocketwiki.local
```

Se o SO negar permissao em `:80`, rode com:

```sh
sudo env "PATH=$PATH" npm run start:lan80
```

Se nao quiser rodar Node com privilegio, mantenha `8787` e coloque um reverse proxy local em `:80` apontando para `127.0.0.1:8787` (Caddy, Nginx, Traefik ou pf no macOS).

### Tailscale

Pelo Tailscale, a URL por IP sempre funciona quando o device esta na tailnet:

```sh
tailscale ip -4
```

Exemplo de acesso:

```text
http://100.x.y.z
```

O `.local` por mDNS e multicast nao atravessa Tailscale de forma confiavel. Na tailnet, trate o IP `100.x` ou o nome MagicDNS `.ts.net` como caminho nativo.

O PocketWiki tambem lista as rotas detectadas:

```sh
curl http://localhost/api/routes
```

Exemplo de retorno:

```json
{
  "portless": true,
  "mdns": ["http://pocketwiki.local"],
  "lan": ["http://192.168.x.x"],
  "tailscale": ["http://100.x.y.z"]
}
```

Se voce preferir HTTPS pelo nome MagicDNS do Tailscale, use Tailscale Serve:

```sh
tailscale serve --bg http://127.0.0.1:80
tailscale serve status
```

Isso cria uma URL HTTPS sem porta no dominio MagicDNS/Tailscale, algo como:

```text
https://nome-da-maquina.nome-da-tailnet.ts.net
```

Nao da para fazer `pocketwiki.local` aparecer automaticamente via Tailscale MagicDNS puro. Para esse nome especifico funcionar na tailnet, use um DNS rewrite/hosts apontando `pocketwiki.local` para o IP Tailscale do PC e rode o PocketWiki em `:80`, ou use reverse proxy/DNS interno.

Caminho pratico:

```sh
tailscale ip -4
```

Pegue o IP `100.x.y.z` do PC e crie uma entrada DNS/hosts:

```text
100.x.y.z pocketwiki.local
```

Se for no celular, o mais simples costuma ser usar o nome MagicDNS `.ts.net` ou configurar esse rewrite no DNS que seus clientes usam dentro da tailnet.

## Local AI

Fluxo governado recomendado:

```text
PocketWiki UI/app ou curl
  -> PocketKernel /v1/kernel
  -> PocketKernel inicia PocketWiki MCP via stdio
  -> PocketWiki MCP devolve evidencia
  -> PocketKernel chama LLM
  -> PocketKernel monta resposta governada
```

O PocketWiki MCP nao envia mensagens para o PocketKernel. Ele e um servidor stdio que o PocketKernel sobe sob demanda. A UI do PocketWiki so participa desse fluxo quando chama o endpoint HTTP do Kernel.

Config do PocketKernel:

```sh
POCKETKERNEL_BASE_URL="http://127.0.0.1:8080"
```

Para subir o PocketKernel consumindo este MCP:

```sh
POCKETKERNEL_WIKI_MCP_COMMAND=node \
POCKETKERNEL_WIKI_MCP_ARGS="/Users/irinery/Documents/pocketwiki/src/mcp/pocketwiki-mcp-server.mjs --root /absolute/path/to/reference/wiki" \
go run ./cmd/pocketkernel -mode serve -addr 127.0.0.1:8080
```

Smoke direto no Kernel:

```sh
curl -sS http://127.0.0.1:8080/v1/kernel \
  -H 'Content-Type: application/json' \
  -d '{"text":"Qual é o status do deploy?","channel":"api","app_id":"pocketwiki","user_id":"u1"}'
```

Sinais esperados no JSON:

- `"profile_used": "wiki"`
- `"missing_evidence": []` quando houver documento confiavel suficiente

Se o MCP nao trouxer evidencia confiavel, o Kernel deve explicitar `missing_evidence`, por exemplo `contexto_requerido_indisponivel` ou `fonte_confiavel_de_status_operacional`.

Provider via MiddlewareAuth:

```sh
MIDDLEWARE_BASE_URL="http://127.0.0.1:18787"
MIDDLEWARE_CLIENT_TOKEN="<token do middlewareAuth>"
MIDDLEWARE_PROJECT_ID="acme"
MIDDLEWARE_LLM_PROFILE_ID="default"
LM_STUDIO_BASE_URL="http://127.0.0.1:1234"
LM_STUDIO_MODEL=""
```

O PocketWiki nao chama LM Studio/OpenAI direto para responder. A tela de IA fica compacta: escolhe `OpenAI` ou `LM Studio`, modelo e raciocinio; URLs, tokens e API key ficam em configuracoes avancadas. OpenAI usa login/status via MiddlewareAuth; LM Studio registra `baseUrl` e `apiKey` no MiddlewareAuth. A pergunta sempre vai para o PocketKernel:

```text
PocketWiki UI
  -> MiddlewareAuth /v1/projects/{projectId}/auth/{openai|lmstudio}/...
  -> PocketKernel /v1/kernel
  -> PocketKernel Harness
  -> LLM/provider configurado
  -> resposta governada
```

Endpoints locais do PocketWiki:

- `POST /api/kernel/query`: proxy para o PocketKernel.
- `POST /api/middleware/lmstudio/api-key`: registra `baseUrl` e `apiKey` no MiddlewareAuth.
- `POST /api/middleware/lmstudio/status`: consulta status do provider LM Studio no MiddlewareAuth.
- `POST /api/middleware/openai/login`: inicia login OpenAI via MiddlewareAuth.
- `POST /api/middleware/openai/status`: consulta status OpenAI via MiddlewareAuth.

Nao existem mais `/api/ai/chat` nem `/api/ai/models` no PocketWiki. A API key do LM Studio fica em memoria na UI e e enviada ao MiddlewareAuth; o bearer `MIDDLEWARE_CLIENT_TOKEN` fica no processo do app/servidor e nao e exposto em `/api/config`.

## Revisao da wiki

A aba Saude tem uma area Revisao com melhorias acionaveis e um prompt dedicado em `prompts/wiki-review.md`. O botao `Copiar prompt` copia o prompt completo para usar em qualquer LLM; o botao `Revisar na IA local` manda o mesmo contexto para o modelo local configurado.

## MCP Evidence Server

A RFC03 esta implementada como servidor MCP local via stdio:

```sh
npm run mcp:evidence -- --root "/absolute/path/to/reference/wiki"
```

Ele nao abre HTTP, nao chama LLM e expoe apenas leitura segura:

- `wiki.search`
- `wiki.get_document`

Sem `--root`, o servidor usa `POCKETWIKI_REFERENCE_PATH` do `.env` ou cai no default `SKILL/wiki-reference`. A resposta de `wiki.get_document` sempre vem com `evidence_only=true` e `redaction_mode=basic`.

Direcao correta: PocketKernel chama este MCP via stdio. PocketWiki UI/app nao chama MCP diretamente e tambem nao "liga" o MCP; quando a UI precisa de resposta governada, ela chama `POST /v1/kernel` no PocketKernel ou o proxy `/api/kernel/query` do servidor PocketWiki.

MCP note: `mcp.json` is for LM Studio/Codex/PocketKernel tools, not for the browser app directly. The filesystem MCP path for this repo should point to:

Use o path absoluto local da sua máquina apontando para `SKILL/`.

See `mcp.example.json`.
