import Foundation

struct ID3Info {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: String?
    var track: Int?
    var disc: Int?
    var picture: Data?
    var pictureType: UInt8?
}

/// MP3 앞쪽의 ID3v2(2.2/2.3/2.4) 태그 읽기. 데이터가 중간에 잘려 있어도 읽은 데까지 돌려준다
enum ID3 {
    /// 태그 전체 길이(헤더 포함). 태그가 없으면 nil
    static func tagSize(_ data: Data) -> Int? {
        let b = [UInt8](data.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let footer = (b[5] & 0x10) != 0 ? 10 : 0
        return 10 + syncsafe(b, 6) + footer
    }

    static func parse(_ data: Data) -> ID3Info? {
        let all = [UInt8](data)
        guard all.count >= 10, all[0] == 0x49, all[1] == 0x44, all[2] == 0x33 else { return nil }
        let version = all[3]
        guard (2...4).contains(version) else { return nil }
        let flags = all[5]
        let size = syncsafe(all, 6)
        var body = Array(all[10..<min(all.count, 10 + size)])
        if version < 4 && (flags & 0x80) != 0 { body = unsync(body) }

        var pos = 0
        if version >= 3 && (flags & 0x40) != 0, body.count >= 4 {
            pos = version == 3 ? 4 + be32(body, 0) : syncsafe(body, 0)
        }

        var info = ID3Info()
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10

        while pos + headerLength <= body.count {
            let idBytes = Array(body[pos..<pos + idLength])
            guard idBytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }),
                  let id = String(bytes: idBytes, encoding: .ascii) else { break }

            let frameSize: Int
            switch version {
            case 2: frameSize = (Int(body[pos + 3]) << 16) | (Int(body[pos + 4]) << 8) | Int(body[pos + 5])
            case 3: frameSize = be32(body, pos + 4)
            default: frameSize = syncsafe(body, pos + 4)
            }
            let frameFlags: UInt16 = version >= 3 ? (UInt16(body[pos + 8]) << 8) | UInt16(body[pos + 9]) : 0
            let start = pos + headerLength
            guard frameSize > 0, start + frameSize <= body.count else { break }
            var frame = Array(body[start..<start + frameSize])
            pos = start + frameSize

            if version == 3 && (frameFlags & 0x00C0) != 0 { continue }   // 압축·암호화 프레임은 건너뜀
            if version == 4 {
                if (frameFlags & 0x000C) != 0 { continue }
                if (frameFlags & 0x0001) != 0 { frame = Array(frame.dropFirst(4)) }
                if (frameFlags & 0x0002) != 0 { frame = unsync(frame) }
            }

            switch id {
            case "TIT2", "TT2": info.title = text(frame)
            case "TPE1", "TP1": info.artist = text(frame)
            case "TALB", "TAL": info.album = text(frame)
            case "TPE2", "TP2": info.albumArtist = text(frame)
            case "TRCK", "TRK": info.track = leadingInt(text(frame))
            case "TPOS", "TPA": info.disc = leadingInt(text(frame))
            case "TYER", "TYE", "TDRC", "TDOR":
                if info.year == nil, let y = text(frame) { info.year = String(y.prefix(4)) }
            case "APIC", "PIC":
                if let pic = picture(frame, v22: id == "PIC"),
                   info.picture == nil || (pic.type == 3 && info.pictureType != 3) {
                    info.picture = pic.data
                    info.pictureType = pic.type
                }
            default:
                break
            }
        }
        return info
    }

    // MARK: - 도우미

    private static func syncsafe(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 3 < b.count else { return 0 }
        return (Int(b[i] & 0x7F) << 21) | (Int(b[i + 1] & 0x7F) << 14) | (Int(b[i + 2] & 0x7F) << 7) | Int(b[i + 3] & 0x7F)
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 3 < b.count else { return 0 }
        return (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    private static func unsync(_ b: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 { i += 2 } else { i += 1 }
        }
        return out
    }

    private static func leadingInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        return Int(s.prefix(while: { $0.isASCII && $0.isNumber }))
    }

    private static func text(_ frame: [UInt8]) -> String? {
        guard let encoding = frame.first else { return nil }
        let decoded = decode(Array(frame.dropFirst()), encoding: encoding)
        let first = decoded?
            .split(separator: "\u{0}", omittingEmptySubsequences: true).first
            .map { String($0).replacingOccurrences(of: "\u{FEFF}", with: "") }
        let trimmed = first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func decode(_ bytes: [UInt8], encoding: UInt8) -> String? {
        switch encoding {
        case 0:
            return legacy(Array(bytes.prefix(while: { $0 != 0 })))
        case 1:
            var b = bytes
            if b.count % 2 == 1 { b.removeLast() }
            if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return String(bytes: b.dropFirst(2), encoding: .utf16BigEndian) }
            if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return String(bytes: b.dropFirst(2), encoding: .utf16LittleEndian) }
            return String(bytes: b, encoding: .utf16LittleEndian)
        case 2:
            var b = bytes
            if b.count % 2 == 1 { b.removeLast() }
            return String(bytes: b, encoding: .utf16BigEndian)
        case 3:
            return String(bytes: bytes, encoding: .utf8) ?? legacy(bytes)
        default:
            return nil
        }
    }

    /// 한국 MP3는 "ISO-8859-1"이라 해 놓고 실제로는 CP949(EUC-KR)인 경우가 많다
    private static let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))

    private static func legacy(_ bytes: [UInt8]) -> String? {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(bytes: bytes, encoding: .ascii) }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        if let s = String(bytes: bytes, encoding: cp949) { return s }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    /// APIC(2.3/2.4) / PIC(2.2) 프레임에서 그림 종류와 이미지 데이터
    private static func picture(_ f: [UInt8], v22: Bool) -> (type: UInt8, data: Data)? {
        guard f.count > 4 else { return nil }
        let encoding = f[0]
        var i = 1
        if v22 {
            i += 3
        } else {
            while i < f.count && f[i] != 0 { i += 1 }
            i += 1
        }
        guard i < f.count else { return nil }
        let type = f[i]
        i += 1
        if encoding == 1 || encoding == 2 {
            while i + 1 < f.count && !(f[i] == 0 && f[i + 1] == 0) { i += 2 }
            i += 2
        } else {
            while i < f.count && f[i] != 0 { i += 1 }
            i += 1
        }
        guard i < f.count else { return nil }
        return (type, Data(f[i...]))
    }
}
