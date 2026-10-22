import Foundation
import Observation

private struct BuiltLibrary {
    let tracks: [Track]
    let albums: [Album]
    let artists: [Artist]
}

/// 드라이브 폴더의 곡 목록과 태그(제목·아티스트·앨범·표지). 폰에 저장해 두고 동기화 때 바뀐 것만 고친다
@MainActor @Observable
final class LibraryStore {
    private(set) var tracks: [Track] = []
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var isSyncing = false
    private(set) var syncError: String?
    private(set) var scanDone = 0
    private(set) var scanTotal = 0
    private(set) var isScanning = false
    private(set) var lastSync: Date?
    private(set) var folderID: String?
    private(set) var folderName: String?

    @ObservationIgnored private var byID: [String: Track] = [:]
    @ObservationIgnored private var pending: [String: Track] = [:]
    @ObservationIgnored private var applyScheduled = false
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var buildGeneration = 0
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private let drive: DriveAPI
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let settings: Settings

    init(drive: DriveAPI, downloads: DownloadManager, settings: Settings) {
        self.drive = drive
        self.downloads = downloads
        self.settings = settings
        let d = UserDefaults.standard
        folderID = d.string(forKey: "folderID")
        folderName = d.string(forKey: "folderName")
        lastSync = d.object(forKey: "lastSync") as? Date
        load()
    }

    var trackCount: Int { byID.count }
    var allIDs: [String] { tracks.isEmpty ? Array(byID.keys) : tracks.map(\.id) }

    func track(_ id: String) -> Track? {
        pending[id] ?? byID[id]
    }

    func album(_ id: String) -> Album? {
        albums.first { $0.id == id }
    }

    func setFolder(id: String, name: String) {
        folderID = id
        folderName = name
        UserDefaults.standard.set(id, forKey: "folderID")
        UserDefaults.standard.set(name, forKey: "folderName")
        Task { await sync() }
    }

    // MARK: - 동기화

    func sync() async {
        guard let folderID, !isSyncing else { return }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let files = try await drive.audioFiles(in: folderID)
            applyPending()
            var list: [Track] = []
            for file in files {
                let size = Int64(file.size ?? "") ?? 0
                if var old = byID[file.id] {
                    if old.md5 != file.md5Checksum || old.size != size {
                        // 드라이브에서 파일이 바뀜 → 태그 다시 읽고 다시 받기
                        old = Track(id: file.id, fileName: file.name, size: size, modified: file.modifiedTime, md5: file.md5Checksum)
                        downloads.remove(file.id)
                    }
                    old.fileName = file.name
                    list.append(old)
                } else {
                    list.append(Track(id: file.id, fileName: file.name, size: size, modified: file.modifiedTime, md5: file.md5Checksum))
                }
            }
            setTracks(list)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: "lastSync")
            downloads.prune(keeping: Set(list.map(\.id)))
            scheduleSave()
            startScan()
        } catch {
            syncError = error.localizedDescription
        }
    }

    // MARK: - 태그 읽기

    private var canScanNow: Bool {
        downloads.isOnline && (!downloads.isExpensive || settings.scanOnCellular)
    }

    func startScan() {
        scanTask?.cancel()
        scanTask = Task { await runScan() }
    }

    func networkChanged() {
        if !isScanning && canScanNow && byID.values.contains(where: { $0.scanned != true }) {
            startScan()
        }
    }

    /// 곡 파일을 다 받았는데 태그를 아직 안 읽었으면 폰 안의 파일에서 읽는다
    func scanLocalIfNeeded(_ id: String) {
        guard let t = track(id), t.scanned != true else { return }
        Task { await scanOne(id) }
    }

    private func runScan() async {
        let todo = byID.values.filter { $0.scanned != true }.map(\.id)
        scanTotal = todo.count
        scanDone = 0
        guard !todo.isEmpty else { return }
        isScanning = true
        defer {
            isScanning = false
            applyPending()
        }
        for batchStart in stride(from: 0, to: todo.count, by: 4) {
            if Task.isCancelled { return }
            let ids = Array(todo[batchStart..<min(batchStart + 4, todo.count)])
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { await self.scanOne(id) }
                }
            }
            scanDone = batchStart + ids.count
        }
    }

    private func scanOne(_ id: String) async {
        guard let t = track(id), t.scanned != true else { return }
        let data: Data
        if let local = downloads.allFiles[id] {
            data = await Self.readHead(local)
        } else {
            guard canScanNow, let fetched = try? await fetchTagBytes(id) else { return }
            data = fetched
        }
        await apply(id, data: data)
    }

    /// 파일 앞부분(태그)만 받기. 앨범 표지가 이미 있으면 그림 부분은 건너뛴다
    private func fetchTagBytes(_ id: String) async throws -> Data {
        let url = drive.mediaURL(id)
        var data = try await drive.get(url, range: "bytes=0-65535")
        guard let total = ID3.tagSize(data), total > data.count else { return data }
        if let info = await Self.parse(data), var probe = track(id), info.album != nil {
            probe.album = info.album
            probe.albumArtist = info.albumArtist
            probe.artist = info.artist
            if ArtStore.exists(ArtStore.key(for: probe.albumKey)) { return data }
        }
        let end = min(total, 4_000_000) - 1
        if end >= data.count {
            data.append(try await drive.get(url, range: "bytes=\(data.count)-\(end)"))
        }
        return data
    }

    private func apply(_ id: String, data: Data) async {
        let info = await Self.parse(data)
        guard var t = track(id) else { return }
        if let info {
            t.title = info.title
            t.artist = info.artist
            t.album = info.album
            t.albumArtist = info.albumArtist
            t.trackNo = info.track
            t.discNo = info.disc
            t.year = info.year
        }
        t.scanned = true
        let key = t.album.nonEmpty != nil ? ArtStore.key(for: t.albumKey) : ArtStore.key(for: "track-" + id)
        if ArtStore.exists(key) {
            t.artKey = key
        } else if let picture = info?.picture, await Self.saveArt(picture, key: key) {
            t.artKey = key
        } else {
            t.artKey = nil
        }
        queueUpdate(t)
    }

    func setDuration(_ duration: Double, for id: String) {
        guard var t = track(id), abs((t.duration ?? -1) - duration) > 0.5 else { return }
        t.duration = duration
        queueUpdate(t)
    }

    private nonisolated static func parse(_ data: Data) async -> ID3Info? {
        ID3.parse(data)
    }

    private nonisolated static func saveArt(_ data: Data, key: String) async -> Bool {
        ArtStore.save(data, key: key)
    }

    private nonisolated static func readHead(_ url: URL) async -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let first = try? handle.read(upToCount: 10), let total = ID3.tagSize(first) else { return Data() }
        try? handle.seek(toOffset: 0)
        return (try? handle.read(upToCount: min(total, 4_000_000))) ?? Data()
    }

    // MARK: - 목록 만들기

    private func queueUpdate(_ t: Track) {
        pending[t.id] = t
        guard !applyScheduled else { return }
        applyScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            applyScheduled = false
            applyPending()
        }
    }

    private func applyPending() {
        guard !pending.isEmpty else { return }
        for (id, t) in pending where byID[id] != nil {
            byID[id] = t
        }
        pending.removeAll()
        setTracks(Array(byID.values))
        scheduleSave()
    }

    private func setTracks(_ list: [Track]) {
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        buildGeneration += 1
        let generation = buildGeneration
        Task {
            let built = await Task.detached(priority: .userInitiated) { Self.build(list) }.value
            guard generation == buildGeneration else { return }
            for t in built.tracks where pending[t.id] == nil { byID[t.id] = t }
            tracks = built.tracks
            albums = built.albums
            artists = built.artists
        }
    }

    private nonisolated static func build(_ input: [Track]) -> BuiltLibrary {
        var groups: [String: [Track]] = [:]
        for t in input { groups[t.albumKey, default: []].append(t) }

        // 같은 앨범의 다른 곡에 표지가 있으면 함께 쓴다
        var artByAlbum: [String: String] = [:]
        for (key, list) in groups {
            if let art = list.first(where: { $0.artKey != nil })?.artKey { artByAlbum[key] = art }
        }
        let tracks = input.map { t -> Track in
            guard t.artKey == nil, let art = artByAlbum[t.albumKey] else { return t }
            var copy = t
            copy.artKey = art
            return copy
        }.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }

        var albumTracks: [String: [Track]] = [:]
        for t in tracks { albumTracks[t.albumKey, default: []].append(t) }
        let albums = albumTracks.map { key, list -> Album in
            let sorted = list.sorted(by: Track.albumOrder)
            let first = sorted[0]
            let names = Set(sorted.map(\.displayArtist))
            let artist = first.albumArtist.nonEmpty ?? (names.count == 1 ? first.displayArtist : "여러 아티스트")
            return Album(id: key, title: first.displayAlbum, artist: artist, tracks: sorted)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        var byArtist: [String: (name: String, tracks: [Track])] = [:]
        for t in tracks {
            byArtist[t.displayArtist.lowercased(), default: (t.displayArtist, [])].tracks.append(t)
        }
        let artists = byArtist.map { key, value -> Artist in
            var perAlbum: [String: [Track]] = [:]
            for t in value.tracks { perAlbum[t.albumKey, default: []].append(t) }
            let albums = perAlbum.map { albumKey, list -> Album in
                let sorted = list.sorted(by: Track.albumOrder)
                return Album(id: albumKey, title: sorted[0].displayAlbum, artist: value.name, tracks: sorted)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return Artist(id: key, name: value.name, albums: albums, trackCount: value.tracks.count)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return BuiltLibrary(tracks: tracks, albums: albums, artists: artists)
    }

    // MARK: - 저장

    private var fileURL: URL { Paths.support.appendingPathComponent("library.json") }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Track].self, from: data) else { return }
        setTracks(list)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            saveScheduled = false
            let list = Array(byID.values)
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
