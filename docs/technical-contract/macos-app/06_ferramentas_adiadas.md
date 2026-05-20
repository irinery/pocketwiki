# 06 — Ferramentas Adiadas

## 2.1 — O que é

Registro explícito do que tem dificuldade `4/5` ou maior e não deve ser implementado nesta etapa.

Responsabilidades explícitas:
- documentar itens adiados;
- preservar espaço arquitetural para implementação futura;
- impedir que a primeira branch tente resolver grafo, IA streaming ou renderer oficial.

Não é responsabilidade deste componente:
- implementar qualquer item listado;
- criar APIs definitivas para rede/IA;
- escolher bibliotecas futuras.

## 2.2 — Testes obrigatórios

TESTE DEFER-01
dado:    app macOS compilado
quando:  a navegação principal é aberta
então:   não existe tela ativa de grafo interativo

TESTE DEFER-02
dado:    app macOS compilado
quando:  a tela de leitor é aberta
então:   não existe chamada de rede para LM Studio

TESTE DEFER-03
dado:    arquivo Excalidraw válido
quando:  a tela Excalidraw é aberta
então:   o preview exibido é textual/fallback, não renderer oficial fiel

## 2.3 — Implementação

Itens adiados:

```yaml
deferred:
  graph:
    difficulty: 4
    reason: "layout visual, pan/zoom, colisão, clique e responsividade exigem motor próprio ou biblioteca dedicada"
  local_ai_streaming:
    difficulty: 4
    reason: "seleção de contexto, streaming, estados parciais, erros de rede e privacidade precisam contrato próprio"
  excalidraw_official_render:
    difficulty: 5
    reason: "renderer atual depende de JavaScript/@excalidraw/utils; equivalente Swift fiel não existe no projeto"
```

Tabela de decisão:

| Pedido futuro | Caminho |
| --- | --- |
| grafo visual | nova fase com canvas/layout dedicado |
| IA local | nova fase com cliente HTTP e contrato de privacidade |
| Excalidraw fiel | avaliar WebAssembly/JS bridge ou renderer nativo separado |

Limites:
- nenhum desses itens entra na branch inicial;
- UI pode mencionar que a capacidade está adiada, sem botão quebrado.

Regras de falha:
- não deixar stubs que pareçam funcionais;
- não chamar endpoint inexistente;
- não adicionar dependência pesada não usada.

## 2.4 — Entrega mínima

- lista documentada de itens `4/5+`
- ausência de implementação ativa desses itens
- todos os testes `DEFER-01` a `DEFER-03` passando
