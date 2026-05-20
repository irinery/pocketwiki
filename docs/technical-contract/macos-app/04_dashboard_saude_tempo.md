# 04 — Dashboard, Saúde e Tempo

## 2.1 — O que é

Telas nativas para visão executiva da wiki, fila de revisão e linha do tempo.

Responsabilidades explícitas:
- exibir KPIs de páginas, links, desenhos e ausentes;
- listar hubs, órfãos, links quebrados, tags e recentes;
- calcular score heurístico de saúde;
- gerar checklist de melhorias;
- ordenar timeline por data detectada.

Não é responsabilidade deste componente:
- corrigir arquivos automaticamente;
- chamar LLM;
- editar tags ou frontmatter;
- desenhar grafo.

## 2.2 — Testes obrigatórios

TESTE DASH-01
dado:    índice com páginas, links e ausentes
quando:  métricas de dashboard são calculadas
então:   totais de páginas, links e ausentes batem com o índice

TESTE DASH-02
dado:    página sem backlinks e não especial
quando:  órfãos são calculados
então:   a página aparece na lista de órfãos

TESTE DASH-03
dado:    página com links quebrados
quando:  saúde é calculada
então:   a página gera issue de prioridade alta

TESTE DASH-04
dado:    página com data maior que 180 dias
quando:  saúde é calculada
então:   a página aparece como conteúdo antigo

TESTE DASH-05
dado:    páginas com datas distintas
quando:  timeline é montada
então:   a ordem é decrescente por data

## 2.3 — Implementação

Estruturas:

```yaml
WikiHealthIssue:
  id: String
  priority: enum(high, medium, low)
  title: String
  detail: String
  pageIDs: [String]

WikiDashboardMetrics:
  pages: Int
  links: Int
  drawings: Int
  missingDestinations: Int
  healthScore: Int
```

Tabela de decisão:

| Condição | Issue |
| --- | --- |
| link ausente | prioridade `high` |
| página isolada | prioridade `high` |
| sem backlink | prioridade `medium` |
| sem resumo | prioridade `medium` |
| mais de 180 dias | prioridade `low` |
| sem tags | prioridade `low` |

Limites:
- score mínimo: `0`;
- score máximo: `100`;
- corte de conteúdo antigo: `180` dias;
- listas principais mostram no máximo `12` itens por seção.

Regras de falha:
- índice vazio gera dashboard vazio sem crash;
- data inválida é ignorada;
- score nunca fica fora de `0...100`.

## 2.4 — Entrega mínima

- `DashboardView`
- `HealthView`
- `TimelineView`
- cálculo puro em `WikiAnalytics`
- todos os testes `DASH-01` a `DASH-05` passando
