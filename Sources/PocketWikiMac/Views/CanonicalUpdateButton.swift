import SwiftUI

struct CanonicalUpdateButton: View {
    @Bindable var updater: CanonicalUpdater

    var body: some View {
        if let release = updater.availableRelease {
            Button {
                Task { await updater.installAvailableUpdate() }
            } label: {
                HStack(spacing: 7) {
                    if updater.state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(title(for: release))
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .pocketWikiGlass(
                cornerRadius: 14,
                tint: PocketWikiTheme.accent.opacity(0.62),
                interactive: true
            )
            .disabled(updater.state.isBusy)
            .help(helpText(for: release))
        }
    }

    private func title(for release: CanonicalRelease) -> String {
        switch updater.state {
        case .downloading:
            "Baixando…"
        case .installing:
            "Instalando…"
        case .failed:
            "Tentar \(release.tag) novamente"
        default:
            "Atualizar para \(release.tag)"
        }
    }

    private func helpText(for release: CanonicalRelease) -> String {
        if case .failed(_, let message) = updater.state {
            return "Falha anterior: \(message)"
        }
        return "Baixa e instala a build canônica \(release.tag) da main."
    }
}
