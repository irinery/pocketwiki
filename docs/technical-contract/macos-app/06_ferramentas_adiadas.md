# 06 — Ferramentas Adiadas

## 2.1 — O que é

Registro explícito do que tem dificuldade `4/5` ou maior e não deve ser implementado nesta etapa.

Responsabilidades explícitas:
- documentar itens adiados;
- preservar espaço arquitetural para implementação futura;
- impedir que a branch tente resolver grafo visual interativo.

Não é responsabilidade deste componente:
- implementar qualquer item listado;
- escolher bibliotecas futuras.

## 2.2 — Testes obrigatórios

TESTE DEFER-01
dado:    app macOS compilado
quando:  a navegação principal é aberta
então:   não existe tela ativa de grafo interativo

TESTE DEFER-02
dado:    app macOS compilado
quando:  a tela de leitor é aberta
então:   não existe renderização de grafo visual interativo embutida

## 2.3 — Implementação

Itens adiados:

```yaml
deferred:
  graph:
    difficulty: 4
    reason: "layout visual, pan/zoom, colisão, clique e responsividade exigem motor próprio ou biblioteca dedicada"
```

Tabela de decisão:

| Pedido futuro | Caminho |
| --- | --- |
| grafo visual | nova fase com canvas/layout dedicado |

Limites:
- nenhum desses itens entra nesta rodada;
- UI pode mencionar que a capacidade está adiada, sem botão quebrado.

Regras de falha:
- não deixar stubs que pareçam funcionais;
- não chamar endpoint inexistente;
- não adicionar dependência pesada não usada.

## 2.4 — Entrega mínima

- lista documentada de itens `4/5+`
- ausência de implementação ativa desses itens
- todos os testes `DEFER-01` a `DEFER-02` passando

Nota de evolução: IA local/LM Studio saiu da lista de adiados e foi promovida para a fase `07_ia_local_lmstudio.md`. Excalidraw oficial saiu da lista de adiados e foi promovido para a fase `05_excalidraw_textual.md`.
