# 06 — Ferramentas Adiadas

## 2.1 — O que é

Registro explícito do que tem dificuldade `4/5` ou maior e não deve ser implementado nesta etapa.

Responsabilidades explícitas:
- documentar itens adiados;
- preservar espaço arquitetural para implementação futura;
- registrar quando um item sai da lista de adiados e ganha contrato próprio.

Não é responsabilidade deste componente:
- implementar qualquer item ainda listado;
- escolher bibliotecas futuras.

## 2.2 — Testes obrigatórios

TESTE DEFER-01
dado:    app macOS compilado
quando:  a navegação principal é aberta
então:   não existe tela ativa prometendo item ainda adiado

TESTE DEFER-02
dado:    app macOS compilado
quando:  a tela de leitor é aberta
então:   recursos adiados não aparecem como botão quebrado

## 2.3 — Implementação

Itens promovidos:

```yaml
promoted:
  graph:
    difficulty: 4
    reason: "layout visual, pan/zoom, colisão, clique e responsividade exigem motor próprio ou biblioteca dedicada"
    contract: "08_mapa_grafo.md"
```

Itens ainda adiados:

```yaml
deferred: {}
```

Tabela de decisão:

| Pedido futuro | Caminho |
| --- | --- |
| grafo visual | fase `08_mapa_grafo.md` com canvas/layout dedicado |

Limites:
- item listado em `deferred` não entra na rodada;
- UI pode mencionar capacidade adiada, sem botão quebrado.

Regras de falha:
- não deixar stubs que pareçam funcionais;
- não chamar endpoint inexistente;
- não adicionar dependência pesada não usada.

## 2.4 — Entrega mínima

- lista documentada de itens `4/5+`;
- itens promovidos apontam para contrato próprio;
- ausência de implementação ativa dos itens ainda adiados;
- todos os testes `DEFER-01` a `DEFER-02` passando

Nota de evolução: IA local/LM Studio saiu da lista de adiados e foi promovida para a fase `07_ia_local_lmstudio.md`. Excalidraw oficial saiu da lista de adiados e foi promovido para a fase `05_excalidraw_textual.md`. Grafo visual saiu da lista de adiados e foi promovido para a fase `08_mapa_grafo.md`.
