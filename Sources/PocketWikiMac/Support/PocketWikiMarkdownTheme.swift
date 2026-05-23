@preconcurrency import MarkdownUI
import SwiftUI

extension Theme {
    @MainActor
    static var pocketWiki: Theme {
        Theme()
        .text {
            ForegroundColor(PocketWikiTheme.text)
            FontSize(16)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            ForegroundColor(PocketWikiTheme.text)
            BackgroundColor(PocketWikiTheme.bg4.opacity(0.82))
        }
        .strong {
            FontWeight(.semibold)
            ForegroundColor(PocketWikiTheme.text)
        }
        .emphasis {
            FontStyle(.italic)
            ForegroundColor(PocketWikiTheme.dim)
        }
        .link {
            ForegroundColor(PocketWikiTheme.accent)
            UnderlineStyle(.single)
        }
        .heading1 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativeLineSpacing(.em(0.08))
                    .markdownMargin(top: 10, bottom: 14)
                    .markdownTextStyle {
                        FontWeight(.heavy)
                        FontSize(.em(1.82))
                        ForegroundColor(PocketWikiTheme.text)
                    }

                Divider()
                    .overlay(PocketWikiTheme.border)
            }
        }
        .heading2 { configuration in
            VStack(alignment: .leading, spacing: 0) {
                configuration.label
                    .relativeLineSpacing(.em(0.1))
                    .markdownMargin(top: 26, bottom: 12)
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(.em(1.46))
                        ForegroundColor(PocketWikiTheme.text)
                    }

                Divider()
                    .overlay(PocketWikiTheme.border.opacity(0.82))
            }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.1))
                .markdownMargin(top: 22, bottom: 10)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.2))
                    ForegroundColor(PocketWikiTheme.text)
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.1))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    ForegroundColor(PocketWikiTheme.dim)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.1))
                .markdownMargin(top: 16, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.92))
                    ForegroundColor(PocketWikiTheme.dim)
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.1))
                .markdownMargin(top: 16, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(0.86))
                    ForegroundColor(PocketWikiTheme.muted)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.36))
                .markdownMargin(top: 0, bottom: 14)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(PocketWikiTheme.accent.opacity(0.75))
                    .relativeFrame(width: .em(0.18))

                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(PocketWikiTheme.dim)
                    }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .background(PocketWikiTheme.bg2.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PocketWikiTheme.border.opacity(0.7), lineWidth: 1)
            }
            .markdownMargin(top: 4, bottom: 16)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.24))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                        ForegroundColor(PocketWikiTheme.text)
                    }
                    .padding(16)
            }
            .background(PocketWikiTheme.bg2.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(PocketWikiTheme.border, lineWidth: 1)
            }
            .markdownMargin(top: 2, bottom: 16)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.24))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PocketWikiTheme.accent, PocketWikiTheme.bg4)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.45), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: PocketWikiTheme.border))
                .markdownTableBackgroundStyle(
                    .alternatingRows(PocketWikiTheme.bg.opacity(0.55), PocketWikiTheme.bg2.opacity(0.82))
                )
                .markdownMargin(top: 2, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .relativeLineSpacing(.em(0.24))
        }
        .thematicBreak {
            Divider()
                .relativeFrame(height: .em(0.22))
                .overlay(PocketWikiTheme.border)
                .markdownMargin(top: 22, bottom: 22)
        }
    }
}
