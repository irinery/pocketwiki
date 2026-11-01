# Regra — Serialização RFC para Geração de Contratos

## Propósito

Esta regra se aplica quando uma conversa técnica produziu contexto suficiente para gerar
um contrato técnico por fase, **mas o modelo atual não consegue produzir múltiplos
artefatos em uma única resposta**.

Em vez de tentar gerar os contratos diretamente, o modelo deve produzir **um único
documento RFC** — denso, estruturado e autossuficiente — que outro agente (Claude)
vai expandir nos arquivos de contrato individuais usando a regra de geração.

> O RFC não é um resumo. É a especificação completa comprimida em um único arquivo.
> Nenhuma informação necessária para gerar os contratos pode ficar de fora.

---

## Quando ativar

Ative esta regra quando:

- a conversa detalhou como um componente ou funcionalidade deve funcionar
- há contexto suficiente para começar a escrever testes e estruturas de dados
- gerar múltiplos arquivos separados não é possível neste contexto

Não espere que o usuário peça. Quando o contexto estiver maduro, proponha:

```
Tenho contexto suficiente para serializar esta especificação em um RFC.
Isso permitirá que o Claude gere todos os contratos técnicos em sequência.

Fases identificadas:
- [lista]

Gero o RFC agora?
```

Só gere após confirmação.

---

## Estrutura obrigatória do RFC

O documento deve seguir exatamente esta ordem. Nenhuma seção pode ser omitida.
Se uma seção não tiver conteúdo, declarar `N/A — [motivo]` explicitamente.

---

### Cabeçalho

```markdown
# RFC — <nome canônico do componente ou funcionalidade>

**Projeto:** <nome do projeto ou repositório>
**Data:** <YYYY-MM-DD>
**Status:** COMPLETO | PARCIAL
**Fases:** <N> arquivos a gerar
**Gerado por:** <identificação do modelo ou sessão>

> Se Status=PARCIAL, listar aqui os campos que ficaram indefinidos e o motivo.
> Um RFC PARCIAL não deve ser entregue ao agente gerador sem resolução prévia.
```

---

### Seção 1 — Visão Geral

```markdown
## 1. Visão Geral

### 1.1 Problema
<descrição direta do estado atual que justifica esta implementação>

### 1.2 Solução
<em uma frase: o que este conjunto de componentes faz para resolver o problema>

### 1.3 Fora de escopo
<lista explícita do que NÃO será implementado nesta entrega>
```

---

### Seção 2 — Mapa de Fases

Esta seção define exatamente quais arquivos o agente gerador vai produzir e em que ordem.

```markdown
## 2. Mapa de Fases

| Fase | Arquivo         | Nome do componente | Depende de | Paralelizável com |
|------|-----------------|-------------------|------------|-------------------|
| 01   | 01_nome.md      | <nome>            | —          | —                 |
| 02   | 02_nome.md      | <nome>            | 01         | —                 |
| 03   | 03_nome.md      | <nome>            | 01         | 02                |

### Convenções globais
- <convenção 1: ex: "todos os timeouts em milissegundos">
- <convenção 2: ex: "erros sempre retornam objeto {code: string, message: string}">

### Definition of Done global
- [ ] todos os testes de todas as fases passando
- [ ] <critério mensurável 2>
- [ ] <critério mensurável N>
```

---

### Seção 3 — Especificação por Fase

Repetir o bloco abaixo **uma vez para cada fase** identificada no mapa.
A ordem deve respeitar as dependências declaradas no mapa.

````markdown
## 3.N — Fase NN: <nome do componente>

### O que é
<definição direta do componente em 2–4 frases>

**Responsabilidades:**
- <responsabilidade 1>
- <responsabilidade 2>

**Fora do escopo deste componente:**
- <o que não é responsabilidade — fronteira explícita>

---

### Testes obrigatórios

> Estes testes devem ser escritos no contrato antes de qualquer implementação.
> Todos devem ser verificáveis sem ler o código.

```
TESTE NN-01
dado:    <condição de entrada>
quando:  <ação executada>
então:   <comportamento externo observável>

TESTE NN-02
dado:    <condição de falha>
quando:  <ação executada>
então:   <comportamento externo observável — nunca "falha silenciosa">

TESTE NN-03  [edge case]
dado:    <condição de borda>
quando:  <ação executada>
então:   <comportamento externo observável>

TESTE NN-04  [segurança — incluir se o componente lida com entrada externa, rede ou FS]
dado:    <entrada controlada por ator não confiável>
quando:  <ação executada>
então:   <comportamento externo observável>
```

Cobrir obrigatoriamente: caminho feliz · falha · edge case · segurança (se aplicável)

---

### Contratos de interface

> Um bloco por interface exposta por este componente.

```yaml
interface:
  id: IF-NN-<N>
  tipo: function | http | cli | event | file | ipc
  nome: <identificador canônico>

  entrada:
    - campo: <nome>
      tipo: string | int | bool | enum | object | array
      obrigatório: true | false
      validação: <regra explícita, ou "nenhuma">
      valores_enum: []          # preencher apenas se tipo=enum; lista fechada

  saída:
    sucesso:
      tipo: <tipo>
      campos:
        - campo: <nome>
          tipo: <tipo>
    falha:
      valores_possíveis:        # lista fechada — sem "entre outros"
        - code: ERR_X
          quando: <condição>
          ação: <o que o componente faz — nunca "propagar silenciosamente">

  comportamento_em_falha:
    - condição: <o que falhou>
      ação: <ação do componente>
      observável: <o que o chamador vê>
```

---

### Estruturas de dados

> Declarar todos os tipos usados por este componente.
> Campos sem tipo explícito são inválidos.

```yaml
tipo: <NomeDaEstrutura>
campos:
  - nome: <campo>
    tipo: <tipo primitivo ou referência a outro tipo>
    obrigatório: true | false
    default: <valor ou "nenhum">
    limite: <tamanho máximo, range, ou "nenhum">
```

---

### Regras de comportamento

> Tabela de decisão para lógica condicional não trivial.
> Usar quando há mais de duas condições afetando o mesmo resultado.

| Condição A | Condição B | Resultado | Ação |
|------------|------------|-----------|------|
| verdadeiro | qualquer   | ...       | ...  |
| falso      | verdadeiro | ...       | ...  |

**Limites numéricos explícitos:**
- timeout: <valor em ms>
- tamanho máximo de payload: <valor em KB/MB>
- máximo de tentativas: <número>
- <outros limites relevantes>

---

### Dependências desta fase

```yaml
- id: DEP-NN-<N>
  tipo: biblioteca | serviço_externo | componente_interno | variavel_de_ambiente | arquivo
  nome: <identificador exato>
  versão: <versão mínima ou "qualquer">
  papel: <o que este componente usa desta dependência>
  fallback: <o que acontece se indisponível — nunca omitir>
  obrigatória: true | false
```

---

### Entrega mínima desta fase

- [ ] <item concreto 1>
- [ ] <item concreto 2>
- [ ] todos os testes NN-01 a NN-0X passando
````

---

### Seção 4 — Cenários de Falha Transversais

Falhas que afetam múltiplas fases ou não pertencem a uma fase específica.

```markdown
## 4. Cenários de Falha Transversais

> Avaliar cada categoria. Se irrelevante, declarar "N/A — <motivo>".
> Nunca omitir uma categoria sem justificativa.

### Entrada inválida / malformada
<comportamento esperado do sistema>

### Dependência indisponível ou lenta
<comportamento esperado do sistema>

### Estado inconsistente entre fontes de dados
<comportamento esperado do sistema>

### Concorrência / race condition
<comportamento esperado do sistema, ou "N/A — componente é single-threaded por design">

### Exaustão de recurso
<memória, disco, conexões, file descriptors — comportamento esperado>

### Segurança — entrada controlada por ator externo
<o que é bloqueado e como, ou "N/A — componente não expõe superfície externa">

### Timeout em operação normalmente rápida
<comportamento esperado do sistema>
```

---

### Seção 5 — Decisões e Restrições

```markdown
## 5. Decisões e Restrições

> O que não está em discussão. Documenta para o agente gerador não reabrir.

| ID     | Decisão                         | Motivo                        | Reversível |
|--------|---------------------------------|-------------------------------|------------|
| DEC-01 | <o que foi decidido>            | <motivo técnico ou externo>   | sim / não  |
| DEC-02 | ...                             | ...                           | ...        |

**Alternativas descartadas:**
- <alternativa>: descartada porque <motivo>
```

---

## Regras de qualidade do RFC

**Completude**
- nenhum campo de interface pode ter tipo `any` ou `object` sem detalhar subcampos
- nenhuma lista de erros pode terminar com "entre outros" ou equivalente
- nenhum limite numérico pode ser descrito com palavras — sempre número com unidade

**Testes**
- cada fase tem no mínimo: 1 teste de caminho feliz, 1 de falha, 1 de edge case
- testes de segurança são obrigatórios se o componente lida com entrada externa, rede ou sistema de arquivos
- nenhum teste é verificável apenas lendo o código

**Fases**
- cada fase é autossuficiente: pode ser implementada lendo apenas seu bloco + o cabeçalho
- dependências entre fases declaradas no mapa e repetidas no bloco da fase
- se uma fase parecer grande demais, é sinal de que ela precisa ser particionada — fazer isso antes de gerar o RFC

**Status**
- RFC com `Status: PARCIAL` não deve ser entregue para geração de contratos
- campos indefinidos devem aparecer explicitamente como `???` com nota — nunca omitidos

---

## O que nunca fazer

- não resumir decisões técnicas da conversa — transcrever com fidelidade e expandir
- não usar adjetivos como limite numérico: "grande", "rápido", "razoável" são inválidos
- não deixar `comportamento_em_falha` vazio em nenhuma interface
- não omitir categorias de falha transversal sem justificativa explícita
- não gerar o RFC em partes — é um único documento entregue de uma vez
- não marcar `Status: COMPLETO` com campos `???` em aberto
