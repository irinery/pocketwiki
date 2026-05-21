# 03 — Shell, Leitor e Busca

## 2.1 — O que é

Interface SwiftUI principal para abrir wiki, navegar por páginas, ler Markdown e buscar conteúdo.

Responsabilidades explícitas:
- criar layout responsivo com sidebar e área de detalhe;
- listar páginas com filtro e busca;
- abrir página selecionada no leitor;
- renderizar Markdown com renderer SwiftUI dedicado, preservando headings, listas, tabelas, task lists, blockquotes, code blocks e links;
- exibir metadados, tags, backlinks, outlinks e links ausentes;
- oferecer palette/busca global por título, path, resumo e tags.

Não é responsabilidade deste componente:
- calcular saúde global;
- renderizar grafo visual;
- chamar IA;
- editar arquivos Markdown.

## 2.2 — Testes obrigatórios

TESTE UI-01
dado:    índice vazio
quando:  o app abre
então:   a tela mostra ação de abrir pasta e nenhuma lista fantasma

TESTE UI-02
dado:    índice com duas páginas
quando:  o usuário filtra por texto presente em uma página
então:   a sidebar mostra apenas a página compatível

TESTE UI-03
dado:    página com `[[Destino]]` resolvido
quando:  o link é acionado no leitor
então:   a seleção muda para a página destino

TESTE UI-04
dado:    página com link ausente
quando:  o link é exibido
então:   ele aparece marcado como ausente e não navega para página inexistente

TESTE UI-05
dado:    Markdown com HTML `<script>`
quando:  o leitor renderiza o conteúdo
então:   o texto de script não é executado nem vira controle interativo

TESTE UI-06
dado:    página cujo primeiro `# heading` é igual ao título apresentado no cabeçalho
quando:  o leitor renderiza o conteúdo
então:   o heading duplicado é removido do corpo e o restante do Markdown é preservado

TESTE UI-07
dado:    janela com área de detalhe estreita
quando:  uma página está selecionada
então:   o inspector sai da coluna fixa e fica acessível por botão como painel lateral deslizante

## 2.3 — Implementação

Estruturas:

```yaml
WikiTab:
  enum:
    - dashboard
    - reader
    - excalidraw
    - health
    - timeline

WikiSearchResult:
  pageID: String
  title: String
  path: String
  reason: String
```

Tabela de decisão:

| Estado | UI |
| --- | --- |
| sem índice | welcome/empty state |
| carregando | progress view com mensagem |
| página selecionada | leitor + inspector |
| busca ativa | lista filtrada |
| erro carregável | banner compacto no detalhe |

Limites:
- sidebar mantém uma linha de título e uma linha de path;
- palette mostra no máximo 30 resultados;
- inspector mostra no máximo 12 backlinks e 12 outlinks.
- leitor usa `MarkdownUI` em SwiftUI nativo, sem `WebView`;
- wiki-links resolvidos viram URLs internas `pocketwiki://page/<id>`;
- links ausentes viram destaque textual e não navegam.
- inspector fixo só aparece quando a área de detalhe tem largura suficiente;
- em largura estreita, o inspector vira drawer sobreposto acionado pelo botão de informação.

Regras de falha:
- seleção inválida volta para primeira página disponível;
- Markdown inválido deve degradar como texto exibível pelo renderer, sem execução de HTML/script;
- link externo abre pelo sistema somente se tiver esquema `http` ou `https`.

## 2.4 — Entrega mínima

- `ContentView`, `SidebarView`, `ReaderView`, `InspectorView`, `SearchPaletteView`
- comandos de menu para abrir pasta e foco de busca
- navegação por wiki-link resolvido
- todos os testes `UI-01` a `UI-05` passando
