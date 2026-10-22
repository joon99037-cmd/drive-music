import Foundation
import ImageIO
import UIKit
import CryptoKit

/// 앨범 표지: 600px JPEG로 줄여 Art 폴더에 저장, 화면용은 크기별 메모리 캐시
enum ArtStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        return c
    }()

    static func key(for albumKey: String) -> String {
        let digest = SHA256.hash(data: Data(albumKey.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func url(_ key: String) -> URL {
        Paths.art.appendingPathComponent(key + ".jpg")
    }

    static func exists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: url(key).path)
    }

    /// 원본 그림 데이터를 줄여서 저장 (백그라운드에서 호출)
    static func save(_ data: Data, key: String) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return false }
        return (try? jpeg.write(to: url(key), options: .atomic)) != nil
    }

    /// 크기(pt)에 맞춘 이미지. 디스크 읽기·디코딩이 있으니 백그라운드에서 부른다
    static func image(_ key: String, side: CGFloat) -> UIImage? {
        let pixels = Int(side * 3)
        let cacheKey = "\(key)-\(pixels)" as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit }
        guard let full = UIImage(contentsOfFile: url(key).path) else { return nil }
        let target = CGSize(width: pixels, height: pixels)
        let image = (side >= 200 ? full.preparingForDisplay() : full.preparingThumbnail(of: target)) ?? full
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    static func cachedImage(_ key: String, side: CGFloat) -> UIImage? {
        cache.object(forKey: "\(key)-\(Int(side * 3))" as NSString)
    }

    static func removeAll() {
        cache.removeAllObjects()
        try? FileManager.default.removeItem(at: Paths.art)
        try? FileManager.default.createDirectory(at: Paths.art, withIntermediateDirectories: true)
    }
}
