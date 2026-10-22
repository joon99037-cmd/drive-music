import Foundation

struct DriveFile: Decodable, Hashable, Identifiable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let md5Checksum: String?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}

private struct FileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

enum DriveError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "드라이브 오류 \(code): \(body.prefix(200))"
        }
    }
}

@MainActor
final class DriveAPI {
    let auth: GoogleAuth

    init(auth: GoogleAuth) {
        self.auth = auth
    }

    func authorizedRequest(_ url: URL, range: String? = nil, timeout: TimeInterval = 30) async throws -> URLRequest {
        let token = try await auth.validToken()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        return req
    }

    /// 인증 GET. 401이면 토큰을 새로 받아 한 번 더 시도
    func get(_ url: URL, range: String? = nil) async throws -> Data {
        var lastStatus = 0
        for attempt in 0..<2 {
            if attempt > 0 { _ = try await auth.validToken(forceRefresh: true) }
            let req = try await authorizedRequest(url, range: range)
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { lastStatus = status; continue }
            guard (200..<300).contains(status) else {
                throw DriveError.http(status, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        }
        throw DriveError.http(lastStatus, "인증 실패")
    }

    func list(query: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "name"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            let data = try await get(comps.url!)
            let page = try JSONDecoder().decode(FileList.self, from: data)
            all += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func folders(in parent: String) async throws -> [DriveFile] {
        try await list(query: "'\(parent)' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
    }

    /// 폴더 안(하위 폴더 포함)의 모든 오디오 파일
    func audioFiles(in folder: String) async throws -> [DriveFile] {
        var result: [DriveFile] = []
        var stack = [folder]
        var seen = Set<String>()
        while let current = stack.popLast() {
            guard seen.insert(current).inserted else { continue }
            let items = try await list(query: "'\(current)' in parents and trashed = false and (mimeType contains 'audio/' or mimeType = 'application/vnd.google-apps.folder')")
            for item in items {
                if item.isFolder { stack.append(item.id) } else { result.append(item) }
            }
        }
        return result
    }

    func mediaURL(_ id: String) -> URL {
        URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media&supportsAllDrives=true")!
    }
}
