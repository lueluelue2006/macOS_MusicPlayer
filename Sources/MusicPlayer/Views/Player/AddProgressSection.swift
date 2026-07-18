import SwiftUI

struct AddProgressSection: View {
  @ObservedObject var viewModel: PlayerViewModel
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
          .tint(theme.accent)

        VStack(alignment: .leading, spacing: 2) {
          Text(viewModel.addFilesPhase.isEmpty ? "正在处理…" : viewModel.addFilesPhase)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(theme.stagePrimaryText)

          if !viewModel.addFilesDetail.isEmpty {
            Text(viewModel.addFilesDetail)
              .font(.caption2)
              .foregroundColor(theme.stageSecondaryText)
              .lineLimit(1)
          }
        }

        Spacer()

        Button("取消") {
          viewModel.cancelAddFiles()
        }
        .font(.caption)
        .buttonStyle(.borderless)
      }

      if viewModel.addFilesProgressTotal > 0 {
        ProgressView(
          value: Double(viewModel.addFilesProgressCurrent),
          total: Double(viewModel.addFilesProgressTotal)
        )
        .controlSize(.small)

        Text("\(viewModel.addFilesProgressCurrent)/\(viewModel.addFilesProgressTotal)")
          .font(.caption2)
          .foregroundColor(theme.stageSecondaryText)
      } else if viewModel.addFilesProgressCurrent > 0 {
        Text("已发现 \(viewModel.addFilesProgressCurrent) 首")
          .font(.caption2)
          .foregroundColor(theme.stageSecondaryText)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(theme.surface)
    )
  }
}
