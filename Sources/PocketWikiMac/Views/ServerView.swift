import AppKit
import SwiftUI

struct ServerView: View {
    @Bindable var store: WikiAppStore
    @Bindable var updater: CanonicalUpdater
    @AppStorage("PocketWikiMac.localAI.middlewareBaseURL") private var middlewareAuthBaseURL = MiddlewareAuthEndpointPolicy.defaultBaseURL
    @AppStorage("PocketWikiMac.localAI.kernelBaseURL") private var pocketKernelBaseURL = PocketWikiServerConfiguration.defaultPocketKernelBaseURL
    @State private var showsMiddlewarePassword = false
    @State private var middlewareOperationMessage = ""
    @State private var pocketKernelOperationMessage = ""
    @State private var confirmsPasswordRotation = false

    private var publicHostsBinding: Binding<String> {
        Binding(
            get: { store.serverConfiguration.publicHosts.joined(separator: ", ") },
            set: { store.serverConfiguration.publicHosts = PocketWikiRouteBuilder.parsePublicHosts($0) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                Picker("", selection: $store.serverMode) {
                    ForEach(PocketWikiServerMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if store.serverMode == .localMac {
                    localServerPanel
                } else {
                    remoteServerPanel
                }

                pocketKernelPanel
                middlewareAuthPanel
                logsPanel
            }
            .padding(22)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(PocketWikiTheme.appBackground)
        .task {
            if middlewareAuthBaseURL == MiddlewareAuthEndpointPolicy.defaultBaseURL,
               store.serverConfiguration.middlewareAuthBaseURL != MiddlewareAuthEndpointPolicy.defaultBaseURL {
                middlewareAuthBaseURL = store.serverConfiguration.middlewareAuthBaseURL
            }
            await refreshMiddlewareAuth()
            if pocketKernelBaseURL == PocketWikiServerConfiguration.defaultPocketKernelBaseURL,
               store.serverConfiguration.pocketKernelBaseURL != PocketWikiServerConfiguration.defaultPocketKernelBaseURL {
                pocketKernelBaseURL = store.serverConfiguration.pocketKernelBaseURL
            }
            await refreshPocketKernel()
        }
        .confirmationDialog(
            "Gerar uma nova senha?",
            isPresented: $confirmsPasswordRotation,
            titleVisibility: .visible
        ) {
            Button("Gerar e invalidar a anterior", role: .destructive) {
                Task { await rotateMiddlewarePassword() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("O helper será reiniciado e a senha anterior deixará de funcionar imediatamente.")
        }
    }

    private var pocketKernelPanel: some View {
        SectionCard(
            "PocketKernel add-on",
            subtitle: pocketKernelStatusSubtitle,
            systemImage: "cpu.fill"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(pocketKernelStatusColor)
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.pocketKernelAddon.status.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PocketWikiTheme.text)
                        Text(pocketKernelModeBinding.wrappedValue.detail)
                            .font(.caption)
                            .foregroundStyle(PocketWikiTheme.muted)
                    }

                    Spacer()

                    if let processID = store.pocketKernelAddon.managedProcessID {
                        Text("PID \(processID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(PocketWikiTheme.good)
                    }
                }

                Picker("Execução", selection: pocketKernelModeBinding) {
                    ForEach(PocketKernelAddonMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text(pocketKernelModeBinding.wrappedValue == .external ? "Endpoint remoto" : "Endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketWikiTheme.muted)
                    TextField(PocketWikiServerConfiguration.defaultPocketKernelBaseURL, text: $pocketKernelBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .disabled(pocketKernelModeBinding.wrappedValue == .disabled)
                        .onSubmit { Task { await refreshPocketKernel() } }
                }

                HStack(spacing: 10) {
                    middlewareCheck(
                        "Serviço HTTP",
                        ready: store.pocketKernelAddon.healthAvailable,
                        systemImage: "network"
                    )
                    middlewareCheck(
                        "MCP Evidence",
                        ready: store.pocketKernelAddon.mcpAvailable,
                        systemImage: "point.3.connected.trianglepath.dotted"
                    )
                    middlewareCheck(
                        "Ponte provider",
                        ready: store.pocketKernelAddon.providerAvailable,
                        systemImage: "arrow.triangle.branch"
                    )
                }

                addonBuildStatus(
                    service: .pocketKernel,
                    integrity: store.pocketKernelAddon.integrityStatus
                )

                Button {
                    Task { await refreshPocketKernel() }
                } label: {
                    Label(
                        store.pocketKernelAddon.status.isReady ? "Validar novamente" : "Conectar",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketWikiTheme.accent2)
                .disabled(pocketKernelModeBinding.wrappedValue == .disabled)

                if !pocketKernelOperationMessage.isEmpty {
                    Text(pocketKernelOperationMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(store.pocketKernelAddon.healthAvailable ? PocketWikiTheme.dim : PocketWikiTheme.warn)
                        .textSelection(.enabled)
                }

                Text(pocketKernelBoundaryNotice)
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.muted)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PocketWikiIcon(kind: .server, size: 34)
                .foregroundStyle(statusColor)
                .frame(width: 48, height: 48)
                .pocketWikiSurface(cornerRadius: 16, tint: statusColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Servidor")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(PocketWikiTheme.text)
                Text(store.serverIndicatorDetail)
                    .foregroundStyle(PocketWikiTheme.dim)
                    .lineLimit(2)
            }

            Spacer()

            ServerStatusPill(store: store, showsDetail: false)
        }
        .padding(18)
        .pocketWikiCard(hero: true)
    }

    private var localServerPanel: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
            SectionCard("Este Mac serve", subtitle: store.serverIndicatorTitle, systemImage: "server.rack") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await store.toggleLocalServer() }
                        } label: {
                            Label(localServerButtonTitle, systemImage: localServerButtonIcon)
                                .frame(minWidth: 150)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(isLocalServerRunning ? PocketWikiTheme.bad : PocketWikiTheme.good)
                        .buttonBorderShape(.roundedRectangle(radius: 8))

                        Button {
                            store.serverConfiguration = PocketWikiServerConfiguration.load()
                        } label: {
                            Label("Recarregar .env", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                        .disabled(isLocalServerRunning)

                        Button {
                            openWebRoute()
                        } label: {
                            Label("Abrir web", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                        .disabled(activeRoutes == nil)
                    }

                    configFields
                }
            }

            SectionCard("Rotas publicadas", subtitle: routeSubtitle, systemImage: "network") {
                routeList
            }

            SectionCard("MCP Evidence", subtitle: store.localMCPEvidence.status, systemImage: "point.3.connected.trianglepath.dotted") {
                mcpEvidencePanel(store.localMCPEvidence, allowCopy: true)
            }
        }
    }

    private var remoteServerPanel: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], alignment: .leading, spacing: 16) {
            SectionCard("Servidor externo", subtitle: "cliente nativo", systemImage: "link") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("http://pocketwiki.local", text: $store.remoteServerURLText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button {
                            Task { await store.connectRemoteServer() }
                        } label: {
                            Label("Conectar", systemImage: "bolt.horizontal")
                                .frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(PocketWikiTheme.accent)
                        .buttonBorderShape(.roundedRectangle(radius: 8))

                        Button {
                            store.disconnectRemoteServer()
                        } label: {
                            Label("Desconectar", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.roundedRectangle(radius: 8))
                    }

                    Text(store.remoteConnectionMessage)
                        .font(.callout)
                        .foregroundStyle(store.remoteConnectionMessage.lowercased().contains("falhou") ? PocketWikiTheme.bad : PocketWikiTheme.dim)
                }
            }

            SectionCard("Fonte ativa", subtitle: store.sourceMode.title, systemImage: "externaldrive.connected.to.line.below") {
                VStack(alignment: .leading, spacing: 8) {
                    MetricTile(title: "Paginas", value: "\(store.index.pages.count)", systemImage: "doc.text")
                    Text(store.statusMessage)
                        .font(.callout)
                        .foregroundStyle(PocketWikiTheme.dim)
                }
            }

            SectionCard("MCP Evidence", subtitle: store.remoteMCPEvidence?.status ?? "nao anunciado", systemImage: "point.3.connected.trianglepath.dotted") {
                if let evidence = store.remoteMCPEvidence {
                    mcpEvidencePanel(evidence, allowCopy: false)
                } else {
                    Text("Conecte um servidor com /api/config atualizado para ver o MCP Evidence anunciado.")
                        .font(.callout)
                        .foregroundStyle(PocketWikiTheme.muted)
                }
            }
        }
    }

    private var middlewareAuthPanel: some View {
        SectionCard(
            "MiddlewareAuth add-on",
            subtitle: middlewareStatusSubtitle,
            systemImage: "person.badge.key.fill"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(middlewareStatusColor)
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.middlewareAuthAddon.status.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PocketWikiTheme.text)
                        Text(middlewareModeBinding.wrappedValue.detail)
                            .font(.caption)
                            .foregroundStyle(PocketWikiTheme.muted)
                    }

                    Spacer()

                    if let processID = store.middlewareAuthAddon.managedProcessID {
                        Text("PID \(processID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(PocketWikiTheme.good)
                    }
                }

                Picker("Execução", selection: middlewareModeBinding) {
                    ForEach(MiddlewareAuthAddonMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 6) {
                    Text(middlewareModeBinding.wrappedValue == .external ? "Endpoint remoto" : "Endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketWikiTheme.muted)
                    TextField(MiddlewareAuthEndpointPolicy.defaultBaseURL, text: $middlewareAuthBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .disabled(middlewareModeBinding.wrappedValue == .disabled)
                        .onSubmit {
                            Task { await refreshMiddlewareAuth() }
                        }
                }

                middlewareAccessChecks

                addonBuildStatus(
                    service: .middlewareAuth,
                    integrity: store.middlewareAuthAddon.integrityStatus
                )

                if middlewareUsesManagedPassword {
                    managedPasswordPanel
                } else if middlewareModeBinding.wrappedValue != .disabled {
                    externalPasswordPanel
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await refreshMiddlewareAuth() }
                    } label: {
                        Label(
                            store.middlewareAuthAddon.status.isReady ? "Validar novamente" : "Conectar",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketWikiTheme.accent)
                    .disabled(middlewareModeBinding.wrappedValue == .disabled)

                    if middlewareUsesManagedPassword {
                        Button {
                            confirmsPasswordRotation = true
                        } label: {
                            Label("Gerar nova senha", systemImage: "key.horizontal")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !middlewareOperationMessage.isEmpty {
                    Text(middlewareOperationMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(
                            middlewareOperationMessage.lowercased().contains("falha")
                                ? PocketWikiTheme.bad
                                : PocketWikiTheme.dim
                        )
                        .textSelection(.enabled)
                }

                Text(middlewareBoundaryNotice)
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.muted)
            }
        }
    }

    private var middlewareAccessChecks: some View {
        HStack(spacing: 10) {
            middlewareCheck(
                "Serviço HTTP",
                ready: store.middlewareAuthAddon.healthAvailable,
                systemImage: "network"
            )
            middlewareCheck(
                "Senha/API",
                ready: store.middlewareAuthAddon.accessVerified,
                systemImage: "lock.shield"
            )
        }
    }

    private var managedPasswordPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Senha gerenciada pelo PocketWiki")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.muted)

            HStack(spacing: 8) {
                Group {
                    if showsMiddlewarePassword {
                        Text(store.middlewareAuthClientToken.pocketIfEmpty("senha ainda não gerada"))
                            .textSelection(.enabled)
                    } else {
                        Text(store.middlewareAuthClientToken.isEmpty ? "senha ainda não gerada" : String(repeating: "•", count: 24))
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .pocketWikiSurface(cornerRadius: 8)

                Button {
                    showsMiddlewarePassword.toggle()
                } label: {
                    Image(systemName: showsMiddlewarePassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .help(showsMiddlewarePassword ? "Ocultar senha" : "Mostrar senha")

                Button {
                    copyToClipboard(store.middlewareAuthClientToken)
                    middlewareOperationMessage = "Senha copiada."
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(store.middlewareAuthClientToken.isEmpty)
                .help("Copiar senha")
            }
        }
    }

    private var externalPasswordPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Senha emitida pelo servidor remoto")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.muted)
            SecureField("MIDDLEWARE_CLIENT_TOKEN", text: $store.middlewareAuthClientToken)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit {
                    Task { await refreshMiddlewareAuth() }
                }
            Text("O PocketWiki não consegue trocar a senha de um servidor que ele não iniciou.")
                .font(.caption)
                .foregroundStyle(PocketWikiTheme.warn)
        }
    }

    private func middlewareCheck(_ title: String, ready: Bool, systemImage: String) -> some View {
        Label(title, systemImage: ready ? "checkmark.circle.fill" : systemImage)
            .font(.caption.monospaced())
            .foregroundStyle(ready ? PocketWikiTheme.good : PocketWikiTheme.warn)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .pocketWikiSurface(cornerRadius: 9, tint: ready ? PocketWikiTheme.good : PocketWikiTheme.warn)
    }

    private func addonBuildStatus(
        service: PocketAddonService,
        integrity: PocketAddonIntegrityStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: integrityIcon(integrity))
                    .foregroundStyle(integrityColor(integrity))
                Text(integrity.title)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.dim)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if updater.availableRelease != nil {
                    CanonicalUpdateButton(updater: updater)
                }
            }

            Text(addonUpdateMessage(service: service, integrity: integrity))
                .font(.caption)
                .foregroundStyle(addonUpdateColor(service: service, integrity: integrity))
        }
        .padding(10)
        .pocketWikiSurface(cornerRadius: 11, tint: integrityColor(integrity))
    }

    private func addonUpdateMessage(
        service: PocketAddonService,
        integrity: PocketAddonIntegrityStatus
    ) -> String {
        guard let release = updater.availableRelease else {
            return "Atualização atômica: o helper é validado e substituído junto com o PocketWiki.app."
        }
        guard let remoteBuild = release.addonBuilds?.build(for: service) else {
            return "A release \(release.tag) não publicou a versão deste add-on; o ZIP ainda será bloqueado se binário, manifesto ou SHA-256 forem inválidos."
        }
        guard case .verified(let localBuild) = integrity else {
            return "A release \(release.tag) contém \(service.title) \(remoteBuild.shortRef); a instalação validará o helper antes de substituir o app."
        }
        if localBuild.ref == remoteBuild.ref {
            return "A release \(release.tag) mantém este add-on em \(remoteBuild.shortRef); não há atualização do serviço."
        }
        return "A release \(release.tag) atualizará este add-on: \(localBuild.shortRef) → \(remoteBuild.shortRef). O processo será reiniciado com o app."
    }

    private func addonUpdateColor(
        service: PocketAddonService,
        integrity: PocketAddonIntegrityStatus
    ) -> Color {
        guard let remoteBuild = updater.availableRelease?.addonBuilds?.build(for: service),
              case .verified(let localBuild) = integrity else {
            return PocketWikiTheme.muted
        }
        return localBuild.ref == remoteBuild.ref ? PocketWikiTheme.dim : PocketWikiTheme.warn
    }

    private func integrityIcon(_ integrity: PocketAddonIntegrityStatus) -> String {
        switch integrity {
        case .verified: "checkmark.shield.fill"
        case .failed: "xmark.shield.fill"
        case .externalUntracked: "questionmark.diamond.fill"
        case .notChecked: "shield"
        }
    }

    private func integrityColor(_ integrity: PocketAddonIntegrityStatus) -> Color {
        switch integrity {
        case .verified: PocketWikiTheme.good
        case .failed: PocketWikiTheme.bad
        case .externalUntracked: PocketWikiTheme.warn
        case .notChecked: PocketWikiTheme.muted
        }
    }

    private var configFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Porta").foregroundStyle(PocketWikiTheme.muted)
                TextField("8787", value: $store.serverConfiguration.port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(isLocalServerRunning)
            }
            GridRow {
                Text("Bind").foregroundStyle(PocketWikiTheme.muted)
                TextField("0.0.0.0", text: $store.serverConfiguration.bindHost)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLocalServerRunning)
            }
            GridRow {
                Text(".local").foregroundStyle(PocketWikiTheme.muted)
                TextField("pocketwiki.local", text: publicHostsBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isLocalServerRunning)
            }
            GridRow {
                Text("mDNS").foregroundStyle(PocketWikiTheme.muted)
                Toggle("", isOn: $store.serverConfiguration.mdnsEnabled)
                    .labelsHidden()
                    .disabled(isLocalServerRunning)
            }
        }
    }

    @ViewBuilder
    private var routeList: some View {
        if let routes = activeRoutes {
            VStack(alignment: .leading, spacing: 8) {
                routeGroup("Local", routes.local)
                routeGroup("mDNS", routes.mdns)
                routeGroup("LAN", routes.lan)
                routeGroup("Tailscale", routes.tailscale)
                if !routes.portless {
                    Text("URL sem porta exige HTTP em :80, HTTPS em :443, Tailscale Serve ou reverse proxy.")
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.warn)
                }
            }
        } else {
            Text("Ligue o servidor para ver as rotas detectadas.")
                .foregroundStyle(PocketWikiTheme.muted)
        }
    }

    private func routeGroup(_ title: String, _ routes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.muted)
            if routes.isEmpty {
                Text("nenhuma rota")
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.muted)
            } else {
                ForEach(routes, id: \.self) { route in
                    Text(route)
                        .font(.callout.monospaced())
                        .foregroundStyle(PocketWikiTheme.text)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func mcpEvidencePanel(_ evidence: PocketWikiMCPEvidenceStatus, allowCopy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(evidence.title, systemImage: evidence.available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(evidence.status == "ready" ? PocketWikiTheme.good : PocketWikiTheme.warn)
                Spacer(minLength: 8)
                Text(evidence.transport)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketWikiTheme.muted)
            }

            Text(evidence.note)
                .font(.callout)
                .foregroundStyle(PocketWikiTheme.dim)

            VStack(alignment: .leading, spacing: 6) {
                metadataRow("Tools", evidence.tools.joined(separator: ", "))
                metadataRow("Timeout", "\(evidence.timeoutMs) ms / max \(evidence.maxResults)")
                metadataRow("Escopo", evidence.sameHostOnly ? "mesmo host" : "remoto")
            }

            Text(evidence.commandLine)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.text)
                .textSelection(.enabled)
                .lineLimit(3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pocketWikiSurface(cornerRadius: 14)

            if !evidence.argsPortable {
                Text("PocketKernel hoje usa parsing por espaco em POCKETKERNEL_WIKI_MCP_ARGS; path com espaco precisa de wrapper sem espaco.")
                    .font(.caption)
                    .foregroundStyle(PocketWikiTheme.warn)
            }

            if allowCopy {
                Button {
                    copyToClipboard(evidence.pocketKernelEnv)
                } label: {
                    Label("Copiar env PocketKernel", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 8))
            }
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketWikiTheme.muted)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(PocketWikiTheme.dim)
                .textSelection(.enabled)
        }
    }

    private var logsPanel: some View {
        SectionCard("Logs", subtitle: "\(store.serverLogs.count)", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 8) {
                if store.serverLogs.isEmpty {
                    Text("sem eventos ainda")
                        .foregroundStyle(PocketWikiTheme.muted)
                } else {
                    ForEach(store.serverLogs.suffix(80)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(logTime(entry.date))
                                .font(.caption.monospaced())
                                .foregroundStyle(PocketWikiTheme.muted)
                                .frame(width: 66, alignment: .leading)
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.monospaced().weight(.bold))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 54, alignment: .leading)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(PocketWikiTheme.dim)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isLocalServerRunning: Bool {
        if case .running = store.serverStatus { return true }
        if case .starting = store.serverStatus { return true }
        return false
    }

    private var localServerButtonTitle: String {
        isLocalServerRunning ? "Desligar" : "Ligar servidor"
    }

    private var localServerButtonIcon: String {
        isLocalServerRunning ? "power" : "play.fill"
    }

    private var activeRoutes: PocketWikiRouteSnapshot? {
        if case .running(let routes) = store.serverStatus {
            return routes
        }
        return nil
    }

    private var routeSubtitle: String {
        activeRoutes?.preferredURL ?? "desligado"
    }

    private var middlewareModeBinding: Binding<MiddlewareAuthAddonMode> {
        Binding(
            get: { store.middlewareAuthRuntimeMode },
            set: { mode in
                store.middlewareAuthRuntimeMode = mode
                middlewareOperationMessage = ""
                if mode == .managed, !isLoopbackMiddlewareURL(middlewareAuthBaseURL) {
                    middlewareAuthBaseURL = MiddlewareAuthEndpointPolicy.defaultBaseURL
                }
                Task { await refreshMiddlewareAuth() }
            }
        )
    }

    private var pocketKernelModeBinding: Binding<PocketKernelAddonMode> {
        Binding(
            get: { store.pocketKernelRuntimeMode },
            set: { mode in
                store.pocketKernelRuntimeMode = mode
                pocketKernelOperationMessage = ""
                if mode == .managed, !isLoopbackPocketKernelURL(pocketKernelBaseURL) {
                    pocketKernelBaseURL = PocketWikiServerConfiguration.defaultPocketKernelBaseURL
                }
                Task { await refreshPocketKernel() }
            }
        )
    }

    private var pocketKernelStatusSubtitle: String {
        if store.pocketKernelAddon.healthAvailable,
           store.pocketKernelAddon.mcpAvailable,
           store.pocketKernelAddon.providerAvailable {
            return "base, MCP e ponte funcionais"
        }
        if store.pocketKernelAddon.healthAvailable { return "HTTP online; MCP externo ou indisponível" }
        return "indisponível"
    }

    private var pocketKernelStatusColor: Color {
        if store.pocketKernelAddon.healthAvailable,
           store.pocketKernelAddon.mcpAvailable,
           store.pocketKernelAddon.providerAvailable {
            return PocketWikiTheme.good
        }
        if store.pocketKernelAddon.healthAvailable { return PocketWikiTheme.warn }
        switch store.pocketKernelAddon.status {
        case .checking, .starting: return PocketWikiTheme.accent
        case .unavailable, .failed: return PocketWikiTheme.bad
        default: return PocketWikiTheme.muted
        }
    }

    private var pocketKernelBoundaryNotice: String {
        switch store.pocketKernelRuntimeMode {
        case .external:
            "Modo remoto: o PocketWiki só valida e consome /v1/kernel. Processo, MCP e credenciais pertencem ao PocketKernel externo."
        case .disabled:
            "O PocketWiki continua independente; recursos de orquestração e evidência via PocketKernel ficam desligados."
        case .automatic, .managed:
            "O PocketKernel é a base de orquestração dos projetos Pocket, mas mantém binário, configuração e ciclo de vida próprios. O add-on local só escuta em loopback."
        }
    }

    private var middlewareUsesManagedPassword: Bool {
        if store.middlewareAuthAddon.status == .external { return false }
        switch store.middlewareAuthRuntimeMode {
        case .managed:
            return true
        case .automatic:
            return isLoopbackMiddlewareURL(middlewareAuthBaseURL)
        case .external, .disabled:
            return false
        }
    }

    private var middlewareStatusSubtitle: String {
        if store.middlewareAuthAddon.accessVerified { return "online e autenticado" }
        if store.middlewareAuthAddon.healthAvailable { return "online; senha não validada" }
        return "indisponível"
    }

    private var middlewareStatusColor: Color {
        if store.middlewareAuthAddon.accessVerified { return PocketWikiTheme.good }
        if store.middlewareAuthAddon.healthAvailable { return PocketWikiTheme.warn }
        switch store.middlewareAuthAddon.status {
        case .checking, .starting: return PocketWikiTheme.accent
        case .unavailable, .failed: return PocketWikiTheme.bad
        default: return PocketWikiTheme.muted
        }
    }

    private var middlewareBoundaryNotice: String {
        switch store.middlewareAuthRuntimeMode {
        case .external:
            "Modo remoto: este app só consome a URL informada. Exponha o MiddlewareAuth separado via HTTPS, VPN ou reverse proxy."
        case .disabled:
            "O PocketWiki continua funcionando sem o add-on; login e providers via MiddlewareAuth ficam indisponíveis."
        case .automatic, .managed:
            "O helper gerenciado escuta somente em loopback. Ele não publica autenticação na LAN e continua independente do servidor PocketWiki."
        }
    }

    @MainActor
    private func refreshMiddlewareAuth() async {
        middlewareOperationMessage = "Validando serviço e senha..."
        await store.ensureMiddlewareAuthAddon(baseURL: middlewareAuthBaseURL)
        if store.middlewareAuthAddon.accessVerified {
            middlewareOperationMessage = "MiddlewareAuth funcional: health e acesso autenticado confirmados."
        } else if store.middlewareAuthAddon.healthAvailable {
            middlewareOperationMessage = "Serviço online, mas a senha não foi aceita ou não foi informada."
        } else {
            middlewareOperationMessage = store.middlewareAuthAddon.status.title
        }
    }

    @MainActor
    private func refreshPocketKernel() async {
        pocketKernelOperationMessage = "Validando PocketKernel e MCP Evidence..."
        await store.ensurePocketKernelAddon(baseURL: pocketKernelBaseURL)
        if store.pocketKernelAddon.healthAvailable,
           store.pocketKernelAddon.mcpAvailable,
           store.pocketKernelAddon.providerAvailable {
            pocketKernelOperationMessage = "PocketKernel funcional: HTTP, MCP Evidence e ponte interna do provider confirmados. A autenticação é validada na área IA."
        } else if store.pocketKernelAddon.healthAvailable {
            pocketKernelOperationMessage = store.pocketKernelAddon.detail.pocketIfEmpty(
                "PocketKernel HTTP online; o MCP é responsabilidade da instância externa."
            )
        } else {
            pocketKernelOperationMessage = store.pocketKernelAddon.status.title
        }
    }

    @MainActor
    private func rotateMiddlewarePassword() async {
        store.middlewareAuthRuntimeMode = .managed
        if !isLoopbackMiddlewareURL(middlewareAuthBaseURL) {
            middlewareAuthBaseURL = MiddlewareAuthEndpointPolicy.defaultBaseURL
        }
        middlewareOperationMessage = "Gerando senha e reiniciando o helper..."
        do {
            _ = try await store.rotateMiddlewareAuthPassword(baseURL: middlewareAuthBaseURL)
            showsMiddlewarePassword = false
            middlewareOperationMessage = "Nova senha gerada e validada. A senha anterior foi invalidada."
        } catch {
            middlewareOperationMessage = "Falha ao gerar senha: \(error.localizedDescription)"
        }
    }

    private func isLoopbackMiddlewareURL(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue.pocketTrimmed), url.scheme?.lowercased() == "http" else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    private func isLoopbackPocketKernelURL(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue.pocketTrimmed), url.scheme?.lowercased() == "http" else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    private var statusColor: Color {
        switch store.serverStatus {
        case .running:
            PocketWikiTheme.good
        case .remoteConnected:
            PocketWikiTheme.accent2
        case .failed:
            PocketWikiTheme.bad
        case .starting:
            PocketWikiTheme.warn
        case .stopped:
            PocketWikiTheme.muted
        }
    }

    private func color(for level: PocketWikiServerLogEntry.Level) -> Color {
        switch level {
        case .info: PocketWikiTheme.accent2
        case .warning: PocketWikiTheme.warn
        case .error: PocketWikiTheme.bad
        }
    }

    private func logTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func openWebRoute() {
        let route = activeRoutes?.local.first ?? activeRoutes?.mdns.first
        guard let route, let url = URL(string: route) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
