import SwiftUI

// MARK: - Cached Avatar View

/// Displays an avatar image from a URL with in-memory + disk caching.
/// Replaces AsyncImage for avatar use cases to avoid re-downloading
/// the same user avatars on every refresh.
struct CachedAvatarView: View {
    let url: URL?
    let size: CGFloat
    var shape: AvatarShape = .circle
    var placeholder: AnyView?

    @State private var image: NSImage?

    enum AvatarShape {
        case circle
        case roundedRect(cornerRadius: CGFloat)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else if let placeholder {
                placeholder
            } else {
                Circle().fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shapeView)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = nil
            image = await AvatarCache.shared.image(for: url)
        }
    }

    private var shapeView: AnyShape {
        switch shape {
        case .circle:
            AnyShape(Circle())
        case .roundedRect(let cornerRadius):
            AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
