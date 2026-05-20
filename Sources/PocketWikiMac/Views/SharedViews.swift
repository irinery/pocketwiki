import SwiftUI

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            content
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.bold())
                    .monospacedDigit()
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PageListButton: View {
    let page: WikiPage
    let meta: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .lineLimit(1)
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if page.kind == .excalidraw { return "scribble.variable" }
        if !page.missingLinks.isEmpty { return "exclamationmark.triangle" }
        if page.healthClass == .good { return "checkmark.circle" }
        return "doc.text"
    }

    private var iconColor: Color {
        if !page.missingLinks.isEmpty { return .red }
        if page.healthClass == .good { return .green }
        return .secondary
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
