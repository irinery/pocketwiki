# 05 — Excalidraw Desktop

## 2.1 — O que é

Suporte a arquivos Excalidraw no app macOS com duas camadas bem separadas:

- índice textual Swift seguro e pesquisável;
- viewer/editor oficial Excalidraw em bundle web isolado via `WKWebView`.

Responsabilidades explícitas:
- reconhecer `.excalidraw` e `.excalidraw.md`;
- extrair textos de cenas JSON quando possível;
- extrair textos de Markdown Excalidraw quando JSON completo não existir;
- inferir links wiki presentes em textos;
- exibir e editar cenas Excalidraw com `@excalidraw/excalidraw`;
- salvar alterações em wiki local;
- abrir fonte remota em modo somente leitura.

Não é responsabilidade deste componente:
- interpretar imagens embutidas;
- colaboração online/E2EE/share links do excalidraw.com.

## 2.2 — Testes obrigatórios

TESTE DRAW-01
dado:    JSON Excalidraw com elemento texto `Servidor [[Rede]]`
quando:  o arquivo é indexado
então:   a página gerada contém o texto e link para `Rede`

TESTE DRAW-02
dado:    `.excalidraw.md` sem JSON completo mas com linhas textuais
quando:  o arquivo é indexado
então:   o fallback textual contém as linhas úteis

TESTE DRAW-03
dado:    Excalidraw inválido
quando:  o parser roda
então:   o app não quebra e cria fallback vazio com aviso carregável

TESTE DRAW-04
dado:    arquivo Excalidraw com mais de 80 textos
quando:  o preview textual é exibido
então:   apenas os primeiros 80 textos aparecem no preview

TESTE DRAW-05
dado:    `.excalidraw.md` com fence `json`
quando:  o arquivo é indexado
então:   o parser extrai textos e links sem fallback

TESTE DRAW-06
dado:    path de salvamento com `..` ou absoluto
quando:  o app tenta resolver o destino
então:   a escrita é rejeitada antes de tocar no filesystem

## 2.3 — Implementação

Estruturas:

```yaml
ExcalidrawSummary:
  slug: String
  path: String
  title: String
  texts: [String]
  links: [WikiLink]
  relationHints: [String]
  stats:
    elements: Int
    textElements: Int
    links: Int
  fallbackReason: String?
```

Tabela de decisão:

| Entrada | Ação |
| --- | --- |
| JSON com `elements` | extrair elementos `type=text` |
| Markdown com bloco JSON | tentar parsear bloco |
| Markdown sem JSON | extrair linhas úteis do texto |
| JSON inválido | fallback vazio com `fallbackReason` |

Limites:
- preview textual: 80 textos;
- textos vazios são descartados;
- relação textual aceita `->`, `→` e `=>`.

Regras de falha:
- parser nunca lança erro fatal para UI;
- JSON inválido não impede o restante da wiki de carregar;
- conteúdo extraído passa pelo mesmo sanitizador do Markdown.

## 2.4 — Entrega mínima

- `ExcalidrawParser`
- `ExcalidrawView`
- `ExcalidrawWebView`
- bundle `Sources/PocketWikiMac/Resources/ExcalidrawEditor/`
- integração com `WikiIndexer`
- testes `DRAW-01` a `DRAW-06`
- todos os testes `DRAW-01` a `DRAW-06` passando
