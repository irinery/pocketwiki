import SwiftUI

struct WikiTabStrip: View {
    @Binding var selection: WikiTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(WikiTab.allCases) { tab in
                    Button {
                        selection = tab
                    } label: {
                        HStack(spacing: 6) {
                            PocketWikiIcon(kind: tab.iconKind, size: 16)
                            Text(tab.title)
                                .font(.callout.weight(selection == tab ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .foregroundStyle(selection == tab ? PocketWikiTheme.bg : PocketWikiTheme.dim)
                        .background(selection == tab ? PocketWikiTheme.accent : PocketWikiTheme.bg2.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selection == tab ? PocketWikiTheme.accent.opacity(0.4) : PocketWikiTheme.border, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(tab.title)
                }
            }
            .padding(1)
        }
    }
}

struct ServerStatusPill: View {
    @Bindable var store: WikiAppStore
    var showsDetail = true

    var body: some View {
        Button {
            store.selectedTab = .server
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.45), radius: 6)

                Text(store.serverIndicatorTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                if showsDetail {
                    Text(store.serverIndicatorDetail)
                        .font(.caption)
                        .foregroundStyle(PocketWikiTheme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(PocketWikiTheme.text)
            .background(PocketWikiTheme.bg2.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(statusColor.opacity(0.55), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(store.serverIndicatorDetail)
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
}
