# 08 — Mapa com Grafo Visual

## 2.1 — O que é

Grafo visual interativo na aba Mapa para mostrar interconexoes entre arquivos da wiki, inspirado no Graph do Obsidian.

Responsabilidades explicitas:
- construir `GraphSnapshot` canonico a partir do `WikiIndex`;
- representar arquivos, links resolvidos e links ausentes como nos e arestas;
- oferecer escopo Global e Local com profundidade configuravel;
- renderizar em Canvas dentro de WKWebView com layout em Web Worker;
- suportar pan, zoom centrado no cursor, hover, clique, drag/pin e double click para unpin;
- limitar volume renderizado para manter fluidez em wikis grandes.

Nao e responsabilidade deste componente:
- editar arquivos a partir do mapa;
- substituir o leitor/inspector textual;
- implementar a alternativa SpriteKit/Metal nesta rodada;
- adicionar dependencia pesada de grafo.

## 2.2 — Testes obrigatorios

TESTE GRAPH-01
dado:    indice com A -> B -> C -> D
quando:  filtro Local seleciona B com profundidade 1
entao:   aparecem A, B e C; D fica fora

TESTE GRAPH-02
dado:    mesmo indice
quando:  filtro Local seleciona B com profundidade 2
entao:   aparecem A, B, C e D

TESTE GRAPH-03
dado:    link para pagina inexistente
quando:  snapshot e construido
entao:   existe no `orphan_target` e aresta source -> missing/*

TESTE GRAPH-04
dado:    pagina com mais de 200 links
quando:  snapshot e construido
entao:   arestas do no sao truncadas em 200 e `truncated = true`

TESTE GRAPH-05
dado:    GraphView gerado
quando:  testes JS rodam
entao:   filtro, busca, hit test, transformacoes e layout inicial deterministico passam

## 2.3 — Implementacao

Estruturas principais:

```yaml
GraphSnapshot:
  version: Int
  selected_node_id: String?
  focus_node_id: String?
  nodes: [GraphNode]
  edges: [GraphEdge]
  truncated: Bool

GraphNode:
  node_id: String
  label: String
  path: String
  folder: String
  kind: String
  status: active | orphan_target | oversized
  degree_in: Int
  degree_out: Int
  truncated: Bool
  size_bytes: Int

FilterConfig:
  scope: global | local
  depth: 1...10
  selected_node_id: String?
  search_term: String
```

Tabela de decisao:

| Condicao | Comportamento |
| --- | --- |
| escopo Global | usa snapshot completo, limitado a 5000 nos no modelo e 500 nos visiveis no renderer |
| escopo Local com selecao | BFS bidirecional ate profundidade `1...10` |
| escopo Local sem selecao | fallback para Global |
| link ausente | cria no `missing/<slug>` com status `orphan_target` |
| no clicado ativo | seleciona a pagina e permanece na aba Mapa |
| no arrastado | fixa posicao ate double click |

Limites:
- `GraphSnapshot.maxGlobalNodes = 5000`;
- `GraphSnapshot.maxLinksPerNode = 200`;
- renderer recebe ate 500 nos visiveis por filtro;
- arquivo acima de 10 MB vira status `oversized` quando indexado;
- busca e truncada em 200 caracteres;
- layout tem `max_iterations = 500` e timeout de 8 segundos.

## 2.4 — Entrega minima

- `WikiGraphSnapshot`/`GraphSnapshot` testavel;
- `WikiGraphPanel` na aba Mapa com Local/Global, profundidade e busca;
- GraphView web com `graph-core`, `layout-worker`, renderer Canvas e ponte Swift;
- testes Swift cobrindo filtros, orphan targets, truncamento e oversized;
- testes JS cobrindo filtros, transformacoes, hit test e layout inicial;
- `swift build`, `npm run test:graph-view`, `./script/run_core_tests.sh` e `./script/build_and_run.sh --verify` passando.
