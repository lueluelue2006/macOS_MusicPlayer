import SwiftUI

struct RecordSleeveHero: View {
  let image: NSImage?
  let title: String
  let artist: String

  @Environment(\.colorScheme) private var colorScheme
  private var theme: AppTheme { AppTheme(scheme: colorScheme) }

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(theme.panelSurface)
        .frame(width: 286, height: 286)
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.stroke, lineWidth: 1)
        }
        .rotationEffect(.degrees(1.2))
        .offset(x: 7, y: -5)

      if image != nil {
        ZStack {
          Circle()
            .fill(Color.black.opacity(colorScheme == .dark ? 0.92 : 0.88))

          ForEach(1..<8, id: \.self) { ring in
            Circle()
              .stroke(Color.white.opacity(0.05), lineWidth: 1)
              .padding(CGFloat(ring) * 12)
          }

          Circle()
            .fill(theme.accent)
            .frame(width: 58, height: 58)

          Circle()
            .fill(Color.black.opacity(0.82))
            .frame(width: 10, height: 10)
        }
        .frame(width: 252, height: 252)
        .offset(x: 28, y: 3)
      }

      AlbumArtworkView(image: image, title: title, artist: artist)
        .frame(width: 286, height: 286)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.stroke, lineWidth: 1)
        }
        .offset(x: -7, y: 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .shadow(color: theme.subtleShadow, radius: 16, x: 0, y: 9)
  }
}

struct AlbumArtworkView: View {
  let image: NSImage?
  let title: String
  let artist: String

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height)
          ZStack(alignment: .topLeading) {
            Color(red: 0.94, green: 0.36, blue: 0.31)

            Circle()
              .fill(Color.black.opacity(0.88))
              .frame(width: side * 0.80, height: side * 0.80)
              .overlay {
                ZStack {
                  ForEach(1..<7, id: \.self) { ring in
                    Circle()
                      .stroke(Color.white.opacity(0.055), lineWidth: 1)
                      .padding(CGFloat(ring) * side * 0.035)
                  }
                  Circle()
                    .fill(Color(red: 0.98, green: 0.71, blue: 0.35))
                    .frame(width: side * 0.19, height: side * 0.19)
                  Circle()
                    .fill(Color.black.opacity(0.85))
                    .frame(width: side * 0.035, height: side * 0.035)
                }
              }
              .offset(x: side * 0.41, y: side * 0.31)

            VStack(alignment: .leading, spacing: 3) {
              Text(String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)))
                .font(.system(size: side * 0.30, weight: .black, design: .rounded))
                .tracking(-3)
                .foregroundStyle(Color.black.opacity(0.88))
                .lineLimit(1)

              Text(artist.isEmpty ? "LOCAL RECORDS" : artist.uppercased())
                .font(.system(size: max(9, side * 0.035), weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Color.black.opacity(0.68))
                .lineLimit(1)
            }
            .padding(side * 0.08)
            .frame(width: side * 0.63, alignment: .leading)
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image == nil ? "\(title) 的唱片封面占位图" : "\(title) 的专辑封面")
  }
}
