import SwiftUI
import AppKit

struct AppBackgroundView: View {
    let theme: AppTheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                theme.backgroundGradient

                if let image = AppBackgroundAsset.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(theme.backgroundArtworkOpacity)
                        .clipped()
                }

                theme.backgroundArtworkScrim
                theme.backgroundArtworkVignette
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }
}

private enum AppBackgroundAsset {
    static let image: NSImage? = {
        let resourceName = "generated-music-background"
        let url = Bundle.main.url(forResource: resourceName, withExtension: "png")
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png")

        guard let url else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}
