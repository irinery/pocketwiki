# PocketWiki macOS Nativo — Contrato Técnico

## Arquivos gerados

| Ordem | Arquivo | Fase | Dependências | Paralelizável |
| --- | --- | --- | --- | --- |
| 1 | `01_scaffold_seguranca.md` | Scaffold SwiftPM, launcher e acesso seguro à pasta | nenhuma | não |
| 2 | `02_core_indexacao.md` | Modelos, parser e índice local | `01_scaffold_seguranca.md` | não |
| 3 | `03_shell_leitor_busca.md` | Shell SwiftUI, sidebar, leitor e busca | `02_core_indexacao.md` | sim |
| 4 | `04_dashboard_saude_tempo.md` | Dashboard, saúde e timeline | `02_core_indexacao.md` | sim |
| 5 | `05_excalidraw_textual.md` | Excalidraw textual/fallback | `02_core_indexacao.md` | sim |
| 6 | `06_ferramentas_adiadas.md` | Itens dificuldade 4+ anotados e não implementados | nenhuma | sim |
| 7 | `07_ia_local_lmstudio.md` | IA local com LM Studio, streaming e contexto selecionável | `02_core_indexacao.md`, `03_shell_leitor_busca.md` | sim |
| 8 | `08_mapa_grafo.md` | Grafo visual interativo na aba Mapa | `02_core_indexacao.md`, `03_shell_leitor_busca.md` | sim |
| 9 | `09_middleware_auth_addon.md` | MiddlewareAuth gerenciado ou externo | `07_ia_local_lmstudio.md` | sim |
| 10 | `10_pocketkernel_addon.md` | PocketKernel gerenciado com MCP Evidence | `07_ia_local_lmstudio.md`, `09_middleware_auth_addon.md` | sim |

## Convenções globais

| Item | Convenção |
| --- | --- |
| Plataforma mínima | macOS 14.0 |
| Linguagem | Swift 6 |
| Empacotamento | SwiftPM com produto `PocketWikiMac` e bundle local `PocketWiki` |
| Bundle local | `dist/PocketWiki.app` |
| Bundle ID | `com.irinery.PocketWikiMac` |
| Fonte padrão | pasta local escolhida pelo usuário |
| Persistência de acesso | security-scoped bookmark em `UserDefaults` |
| Arquivos indexáveis | `.md`, `.excalidraw`, `.excalidraw.md` |
| Diretórios ignorados | nomes iniciados por `.`, `node_modules`, `dist`, `build`, `.git`, `.pocketwiki-cache` |
| Limite de leitura por arquivo | 5 MiB |
| Datas | `Date` em UTC internamente; exibição via locale do sistema |
| Slug | minúsculo, sem diacríticos, `/` preservado, espaços viram `-`, extensão removida |
| Markdown | renderização local sem executar HTML, scripts ou conteúdo remoto |
| IA local | LM Studio/OpenAI-compatible em endpoint loopback, sem cloud por padrão |

## Definition of Done global

| Critério | Medida objetiva |
| --- | --- |
| Contrato | todos os arquivos `00` a `07` existem e seguem as seções obrigatórias |
| Branch | desenvolvimento feito em `codex/pocketwiki-macos-app` |
| App | `swift build` compila `PocketWikiMac` sem erro |
| Launcher | `./script/build_and_run.sh --verify` cria bundle e encontra processo `PocketWiki` |
| Segurança | bookmark é criado/restaurado e acesso à pasta chama `startAccessingSecurityScopedResource()` quando aplicável |
| Indexação | testes cobrem slug, frontmatter, tags, links, arquivos ignorados e Excalidraw textual |
| UI | telas principais estão navegáveis via SwiftUI; Excalidraw usa WebView isolado |
| Itens 4+ | grafo, Excalidraw oficial e IA local possuem contrato próprio |
