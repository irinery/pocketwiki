import AppKit
import SwiftUI

struct ServerView: View {
    @Bindable var store: WikiAppStore

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

                logsPanel
            }
            .padding(22)
            .frame(maxWidth: 1180, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(PocketWikiTheme.appBackground)
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
