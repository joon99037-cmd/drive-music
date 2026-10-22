import SwiftUI
import UIKit

private struct ImageBox: @unchecked Sendable {
    let image: UIImage?
}

/// 앨범 표지. 디스크 읽기·디코딩은 백그라운드에서
struct ArtworkView: View {
    let key: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 6

    @State private var image: UIImage?

    init(key: String?, size: CGFloat? = nil, corner: CGFloat = 6) {
        self.key = key
        self.size = size
        self.corner = corner
        let side = size ?? 400
        _image = State(initialValue: key.flatMap { ArtStore.cachedImage($0, side: side) })
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        Group {
            if let size {
                content.frame(width: size, height: size)
            } else {
                Color.clear.aspectRatio(1, contentMode: .fit).overlay(content)
            }
        }
        .clipShape(shape)
        .task(id: key) {
            guard let key else {
                image = nil
                return
            }
            let side = size ?? 400
            if let hit = ArtStore.cachedImage(key, side: side) {
                image = hit
                return
            }
            image = await Task.detached(priority: .userInitiated) { ImageBox(image: ArtStore.image(key, side: side)) }.value.image
        }
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemGray4), Color(.systemGray5)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: (size ?? 200) * 0.38, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
