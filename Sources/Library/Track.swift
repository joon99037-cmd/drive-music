import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var fileName: String
    var size: Int64
    var modified: String?
    var md5: String?

    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var discNo: Int?
    var year: String?
    var artKey: String?
    var duration: Double?
    var scanned: Bool?

    var ext: String { (fileName as NSString).pathExtension.lowercased() }

    /// "아티스트 - 제목.mp3" 형식 파일 이름에서 뽑은 값
    private var nameParts: (artist: String?, title: String) {
        var base = (fileName as NSString).deletingPathExtension
        let parts = base.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty, Int(artist) == nil {
                return (artist, title)
            }
        }
        // 앞쪽 트랙 번호("01 ", "01. ", "01-") 떼기
        if let range = base.range(of: #"^\d{1,3}[ .\-_]+"#, options: .regularExpression), range.upperBound < base.endIndex {
            base.removeSubrange(range)
        }
        return (nil, base)
    }

    var displayTitle: String { title.nonEmpty ?? nameParts.title }
    var displayArtist: String { artist.nonEmpty ?? nameParts.artist ?? "알 수 없는 아티스트" }
    var displayAlbum: String { album.nonEmpty ?? "알 수 없는 앨범" }

    /// 앨범 묶음 기준: 앨범 아티스트가 있으면 함께, 없으면 앨범 이름만
    var albumKey: String {
        let albumName = displayAlbum.lowercased()
        if let aa = albumArtist.nonEmpty { return aa.lowercased() + "\u{1F}" + albumName }
        if album.nonEmpty == nil { return "\u{1F}" + displayArtist.lowercased() + "\u{1F}" }
        return "\u{1F}" + albumName
    }

    static func albumOrder(_ a: Track, _ b: Track) -> Bool {
        let da = a.discNo ?? 1, db = b.discNo ?? 1
        if da != db { return da < db }
        let ta = a.trackNo ?? Int.max, tb = b.trackNo ?? Int.max
        if ta != tb { return ta < tb }
        return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
    }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    var artKey: String? { tracks.first(where: { $0.artKey != nil })?.artKey }
    var year: String? { tracks.compactMap(\.year).first }
}

struct Artist: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [Album]
    let trackCount: Int
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
