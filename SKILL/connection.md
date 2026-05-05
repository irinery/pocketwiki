# Conexao da wiki de referencia

Fonte do apontamento:

```sh
POCKETWIKI_REFERENCE_PATH="/absolute/path/to/pocketwiki/SKILL/wiki-reference"
POCKETWIKI_REFERENCE_READONLY=true
POCKETWIKI_PORT=80
POCKETWIKI_BIND_HOST="0.0.0.0"
POCKETWIKI_PUBLIC_HOSTS="pocketwiki.local,pokectwiki.local"
POCKETWIKI_MDNS=true

LM_STUDIO_BASE_URL="http://localhost:1234/v1"
LM_STUDIO_MODEL=""
LM_STUDIO_API_KEY=""
```

`POCKETWIKI_REFERENCE_PATH` aponta para a raiz da wiki de referencia.

`POCKETWIKI_REFERENCE_READONLY=true` indica que a aplicacao deve tratar esse conteudo como imutavel ou quase imutavel, usando leitura/indexacao sem tentar gravar de volta.

O `.env` da raiz do projeto e a fonte local persistente. Para trocar a wiki usada pela aplicacao, mude o valor de `POCKETWIKI_REFERENCE_PATH`.

Observacao pratica: se o app rodar como HTML estatico direto no navegador, o browser nao consegue abrir esse caminho sozinho por causa do sandbox de filesystem. Nesse caso o caminho fica salvo como configuracao do projeto, mas o carregamento direto exige um servidor local/backend ou permissao manual via seletor de pasta.

Para carregar a wiki pelo apontamento salvo e usar IA local, rode o PocketWiki pelo servidor local:

```sh
npm start
```

O servidor le o `.env`, expoe a wiki configurada em modo leitura e faz proxy para o LM Studio. Isso evita colocar o token do LM Studio dentro do HTML.

As rotas locais, LAN e Tailscale detectadas pelo servidor ficam em:

```sh
curl http://localhost/api/routes
```

`pocketwiki.local` funciona na LAN via mDNS/DNS local. Pela tailnet, Tailscale MagicDNS puro nao cria esse nome; use o IP `100.x`, o nome `.ts.net` do Tailscale Serve ou um DNS rewrite/hosts apontando `pocketwiki.local` para o IP Tailscale do PC.

O MCP filesystem e uma integracao separada usada pelo cliente MCP. Exemplo correto para este repo:

```json
{
  "mcpServers": {
    "inery-skills": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/absolute/path/to/pocketwiki/SKILL"
      ]
    }
  }
}
```
