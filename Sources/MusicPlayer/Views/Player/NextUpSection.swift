import SwiftUI

struct NextUpSection: View {
  let file: AudioFile
  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    NextUpPreviewView(file: file)
  }
}
