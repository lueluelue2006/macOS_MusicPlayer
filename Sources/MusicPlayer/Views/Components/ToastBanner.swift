import SwiftUI

enum ToastKind: String, Sendable {
    case info
    case success
    case warning
    case error
    case update
}

struct ToastBanner: View {
    let title: String
    let subtitle: String?
    let kind: ToastKind
    let onTap: (() -> Void)?
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var theme: AppTheme { AppTheme(scheme: colorScheme) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            contentBody

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.mutedText)
                    .padding(10)
            }
            .buttonStyle(PlainButtonStyle())
            .help("关闭")
        }
        .background(backgroundShape)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: theme.subtleShadow, radius: 14, x: 0, y: 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var bannerContent: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(indicatorStyle)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.stagePrimaryText)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(theme.mutedText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 30)
        .padding(.vertical, 14)
        .frame(minWidth: 320, maxWidth: 420, alignment: .leading)
    }

    private var contentBody: some View {
        Group {
            if let onTap {
                Button(action: onTap) { bannerContent }
                    .buttonStyle(PlainButtonStyle())
                    .help("点击打开")
            } else {
                bannerContent
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var indicatorStyle: AnyShapeStyle {
        switch kind {
        case .update:
            return AnyShapeStyle(theme.accent)
        case .success:
            return AnyShapeStyle(theme.success)
        case .error:
            return AnyShapeStyle(theme.destructive)
        case .warning:
            return AnyShapeStyle(theme.warning)
        case .info:
            return AnyShapeStyle(theme.info)
        }
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(theme.elevatedSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.stroke, lineWidth: 1)
            )
    }
}
