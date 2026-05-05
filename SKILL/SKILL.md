---
name: pocketwiki-reference
description: Use esta skill quando precisar localizar, ler ou validar a wiki de referencia configurada para o PocketWiki.
---

# PocketWiki Reference

A wiki de referencia fica apontada no `.env` da raiz do projeto.

Carregue `POCKETWIKI_REFERENCE_PATH` e use esse caminho como fonte de leitura dos arquivos Markdown. Trate esse conteudo como somente leitura quando `POCKETWIKI_REFERENCE_READONLY=true`.

## Links para paginas

Quando apontar uma pagina da wiki no chat, cite o path relativo exatamente como a aplicacao mostra em `Path:`, mantendo a extensao `.md`.

Formato recomendado:

```text
raw/INery/Work/iNery/plugin-architecture.md
```

Formato tambem aceito:

```md
[Plugin architecture](raw/INery/Work/iNery/plugin-architecture.md)
```

Regras:

- Nao use caminho absoluto do sistema para fontes da wiki.
- Nao invente URL `file://`, `http://` ou path fora da wiki.
- Evite trocar espacos por `%20`; preserve o path como aparece no `Path:`.
- A interface do PocketWiki converte qualquer path relativo `*.md`, solto ou em Markdown link, em link clicavel e redireciona para a pagina correspondente no leitor.

Se precisar alterar o local da wiki, ajuste apenas o `.env`. O arquivo `SKILL/connection.md` documenta o contrato esperado pela aplicacao.
