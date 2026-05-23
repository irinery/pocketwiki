# 02 — Core de Indexação

## 2.1 — O que é

Camada pura de domínio que lê arquivos permitidos, extrai metadados Markdown/Excalidraw textual e monta o índice navegável.

Responsabilidades explícitas:
- representar arquivos, páginas, links, seções, tags e problemas de saúde;
- normalizar paths e slugs;
- extrair frontmatter simples, headings, resumo, tags, links wiki e datas;
- resolver outlinks, backlinks e links ausentes;
- ignorar arquivos e diretórios fora do contrato.

Não é responsabilidade deste componente:
- abrir painel de pasta;
- renderizar SwiftUI;
- chamar IA local;
- desenhar grafo visual;
- renderizar Excalidraw oficial.

## 2.2 — Testes obrigatórios

TESTE CORE-01
dado:    o path `Wiki/Minha Página.md`
quando:  o slug é gerado
então:   o resultado é `minha-pagina`

TESTE CORE-02
dado:    Markdown com frontmatter `title`, `summary` e `updated`
quando:  a página é indexada
então:   título, resumo e data vêm do frontmatter

TESTE CORE-03
dado:    Markdown com `#tag`, bloco de código contendo `#nao`
quando:  as tags são extraídas
então:   só `tag` aparece no resultado

TESTE CORE-04
dado:    página A com `[[B|label]]` e página B existente
quando:  o índice resolve links
então:   A tem outlink resolvido para B e B tem backlink para A

TESTE CORE-05
dado:    página A com `[[Nao Existe]]`
quando:  o índice resolve links
então:   A tem link ausente e o índice lista o destino ausente

TESTE CORE-06
dado:    arquivos em `.git`, `node_modules`, `.pocketwiki-cache` e `Notas/a.md`
quando:  a árvore é filtrada
então:   apenas `Notas/a.md` é elegível para leitura

TESTE CORE-07
dado:    arquivo maior que 5 MiB
quando:  a leitura é avaliada
então:   o arquivo é ignorado com motivo `too_large`

TESTE CORE-08
dado:    Markdown sem resumo explícito
quando:  a página é indexada
então:   o primeiro parágrafo útil vira resumo truncado em 180 caracteres

## 2.3 — Implementação

Estruturas:

```yaml
WikiFile:
  id: String
  relativePath: String
  name: String
  sizeBytes: Int
  modifiedAt: Date
  content: String
  kind: enum(markdown, excalidraw, excalidrawMarkdown)

WikiPage:
  id: String
  slug: String
  path: String
  title: String
  folder: String
  content: String
  summary: String
  tags: [String]
  links: [WikiLink]
  outlinks: [WikiResolvedLink]
  backlinks: [String]
  missingLinks: [WikiLink]
  headings: [WikiHeading]
  updatedAt: Date?
  wordCount: Int
  readingMinutes: Int
  kind: enum(markdown, excalidraw)

WikiIndex:
  sourceName: String
  pages: [WikiPage]
  missingLinks: [String: [String]]
  tagIndex: [String: [String]]
  generatedAt: Date
```

Tabela de decisão:

| Entrada | Resultado |
| --- | --- |
| `.md` comum | `kind=markdown` |
| `.excalidraw` JSON | `kind=excalidraw` com fallback textual |
| `.excalidraw.md` | `kind=excalidraw` se houver cena/textos Excalidraw |
| extensão diferente | ignorar |
| diretório oculto/build/cache | ignorar |

Limites:
- tamanho máximo por arquivo: `5 * 1024 * 1024` bytes;
- tempo de leitura estimado: `ceil(wordCount / 210)`, mínimo `1`;
- resumo fallback: 180 caracteres;
- headings indexados: níveis `1` a `4`.

Regras de falha:
- arquivo ilegível é pulado e registrado como erro carregável;
- frontmatter inválido vira dicionário vazio;
- link ambíguo sem destino único vira ausente.

## 2.4 — Entrega mínima

- modelos em `Models/`
- parser e loader em `Services/`
- helpers em `Support/`
- testes unitários `CORE-01` a `CORE-08`
- todos os testes `CORE-01` a `CORE-08` passando
