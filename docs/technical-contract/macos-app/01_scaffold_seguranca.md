# 01 — Scaffold e Segurança

## 2.1 — O que é

Cria o app macOS nativo `PocketWikiMac`, o pacote SwiftPM, o launcher local e a camada de acesso seguro à pasta da wiki.

Responsabilidades explícitas:
- criar executável GUI SwiftUI com `WindowGroup`;
- lançar como `.app` local via `script/build_and_run.sh`;
- permitir escolha de pasta com `NSOpenPanel`;
- persistir a pasta com security-scoped bookmark;
- restaurar a última pasta autorizada na abertura do app.

Não é responsabilidade deste componente:
- parsear conteúdo da wiki;
- renderizar telas de conteúdo;
- fazer rede, LM Studio, mDNS ou servidor Node;
- assinar/notarizar distribuição final.

## 2.2 — Testes obrigatórios

TESTE SCAFFOLD-01
dado:    o repositório com `Package.swift`
quando:  `swift build` é executado
então:   o produto `PocketWikiMac` compila sem erro

TESTE SCAFFOLD-02
dado:    o launcher `script/build_and_run.sh`
quando:  `./script/build_and_run.sh --verify` é executado
então:   `dist/PocketWikiMac.app` é criado e o processo `PocketWikiMac` fica ativo

TESTE SCAFFOLD-03
dado:    uma URL de pasta autorizada
quando:  o bookmark é salvo e carregado
então:   a URL resolvida aponta para a mesma pasta

TESTE SCAFFOLD-04
dado:    uma URL sem permissão ou bookmark inválido
quando:  o app tenta restaurar a fonte
então:   a UI mostra estado sem wiki carregada e não tenta ler arquivos silenciosamente

TESTE SCAFFOLD-05
dado:    uma pasta selecionada pelo usuário
quando:  o carregamento inicia
então:   o acesso chama `startAccessingSecurityScopedResource()` quando o sistema exigir escopo de segurança

## 2.3 — Implementação

Estruturas:

```yaml
WikiSourceBookmark:
  id: String
  url: URL
  displayName: String
  bookmarkData: Data
  isStale: Bool
```

Tabela de decisão:

| Condição | Ação |
| --- | --- |
| bookmark válido e não stale | restaurar pasta e carregar índice |
| bookmark stale mas resolvido | salvar novo bookmark e carregar índice |
| bookmark inválido | apagar bookmark salvo e mostrar estado inicial |
| usuário cancela `NSOpenPanel` | manter estado atual sem erro |
| pasta não acessível | mostrar erro explícito na UI |

Limites:
- `LSMinimumSystemVersion`: `14.0`;
- processo: `PocketWikiMac`;
- bundle: `dist/PocketWikiMac.app`;
- timeout de smoke após abrir app: 1 segundo.

Regras de falha:
- falha de build interrompe o launcher com exit code diferente de `0`;
- falha de acesso à pasta não encerra o app;
- bookmark inválido nunca é reutilizado indefinidamente.

## 2.4 — Entrega mínima

- `Package.swift` com executável `PocketWikiMac`
- `PocketWikiMacApp.swift` com `WindowGroup`
- `WikiBookmarkStore` e `WikiFolderPicker`
- `script/build_and_run.sh` executável
- `.codex/environments/environment.toml`
- todos os testes `SCAFFOLD-01` a `SCAFFOLD-05` passando
