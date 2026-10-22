import Foundation
import Network
import Observation

private final class DownloadJob {
    let id: String
    let ext: String
    let expected: Int64
    var received: Int64
    var task: URLSessionDataTask?
    var handle: FileHandle?
    var paused = false
    var status = 0
    var lastReported = 0.0

    init(id: String, ext: String, expected: Int64, received: Int64) {
        self.id = id
        self.ext = ext
        self.expected = expected
        self.received = received
    }
}

private struct SavedDownloads: Codable {
    var pinned: [String]
    var lastAccess: [String: Double]
}

/// 곡 파일 받기. 지금 곡과 다음 곡들을 먼저, 끊기면 받은 데부터 이어받기(Range),
/// 망이 돌아오거나 바뀌면 기다리지 않고 바로 다시 시도한다
@MainActor @Observable
final class DownloadManager {
    private(set) var cached: Set<String> = []
    private(set) var progress: [String: Double] = [:]
    private(set) var pinned: Set<String> = []
    private(set) var isOnline = true
    private(set) var isExpensive = false
    private(set) var usedBytes: Int64 = 0
    private(set) var offlineRemaining = 0

    @ObservationIgnored var trackInfo: @MainActor (String) -> (size: Int64, ext: String)? = { _ in nil }
    @ObservationIgnored var allTrackIDs: @MainActor () -> [String] = { [] }
    @ObservationIgnored var onCacheChanged: @MainActor (String, URL?) -> Void = { _, _ in }
    @ObservationIgnored var onNetworkChange: @MainActor () -> Void = {}

    @ObservationIgnored private let drive: DriveAPI
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let sessionDelegate: SessionDelegate
    @ObservationIgnored private let monitor = NWPathMonitor()

    @ObservationIgnored private var files: [String: URL] = [:]
    @ObservationIgnored private var sizes: [String: Int64] = [:]
    @ObservationIgnored private var lastAccess: [String: Double] = [:]
    @ObservationIgnored private var window: [String] = []
    @ObservationIgnored private var jobs: [String: DownloadJob] = [:]
    @ObservationIgnored private var taskOwner: [Int: String] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var pathSignature = ""
    @ObservationIgnored private var saveScheduled = false

    private let maxConcurrent = 2

    init(drive: DriveAPI, settings: Settings) {
        self.drive = drive
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20      // 데이터가 20초 끊기면 실패 처리 → 이어받기
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let delegate = SessionDelegate()
        sessionDelegate = delegate
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        delegate.owner = self
        loadState()

        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let signature = "\(online)-\(path.usesInterfaceType(.wifi))-\(path.usesInterfaceType(.cellular))"
            Task { @MainActor in
                self?.pathChanged(online: online, expensive: expensive, signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "drivemusic.network"))
    }

    // MARK: - 바깥에서 쓰는 것

    var allFiles: [String: URL] { files }

    func localURL(for id: String) -> URL? {
        guard let url = files[id] else { return nil }
        lastAccess[id] = Date().timeIntervalSince1970
        return url
    }

    func isPinned(_ id: String) -> Bool { settings.offlineAll || pinned.contains(id) }

    /// 재생 순서대로의 곡 목록 (지금 곡이 맨 앞)
    func setWindow(_ ids: [String]) {
        window = ids
        let now = Date().timeIntervalSince1970
        for id in ids where files[id] != nil { lastAccess[id] = now }
        pump()
    }

    func pin(_ ids: [String]) {
        pinned.formUnion(ids)
        scheduleSave()
        pump()
    }

    func unpin(_ ids: [String]) {
        pinned.subtract(ids)
        scheduleSave()
        enforceLimit()
        pump()
    }

    func remove(_ id: String) {
        if let job = jobs[id] { pause(job) }
        if let ext = trackInfo(id)?.ext { try? FileManager.default.removeItem(at: partURL(id, ext: ext)) }
        removeFile(id)
    }

    /// 드라이브에서 없어진 곡의 파일 정리
    func prune(keeping ids: Set<String>) {
        for id in files.keys where !ids.contains(id) { removeFile(id) }
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "part" {
            let id = url.deletingPathExtension().deletingPathExtension().lastPathComponent
            if !ids.contains(id) { try? FileManager.default.removeItem(at: url) }
        }
        let before = pinned.count
        pinned = pinned.intersection(ids)
        if pinned.count != before { scheduleSave() }
    }

    /// 오프라인 저장·재생 대기 중이 아닌 파일 모두 지우기
    func clearCache() {
        let keep = protectedIDs()
        for id in files.keys where !keep.contains(id) { removeFile(id) }
        scheduleSave()
    }

    func settingsChanged() {
        enforceLimit()
        pump()
    }

    // MARK: - 순서 정하기

    func pump() {
        var wanted: [String] = []
        var seen = Set<String>()
        for id in window where files[id] == nil && seen.insert(id).inserted {
            wanted.append(id)
        }
        let offlineIDs = settings.offlineAll ? allTrackIDs() : pinned.sorted()
        let missing = offlineIDs.filter { files[$0] == nil }
        if offlineRemaining != missing.count { offlineRemaining = missing.count }
        if !isExpensive || settings.offlineOnCellular {
            for id in missing where seen.insert(id).inserted { wanted.append(id) }
        }

        let now = Date()
        let ready = wanted.filter { (retryAfter[$0] ?? .distantPast) <= now }
        let top = isOnline ? Array(ready.prefix(maxConcurrent)) : []
        let topSet = Set(top)
        for (id, job) in jobs where !topSet.contains(id) && !job.paused {
            pause(job)
        }
        for id in top where jobs[id] == nil {
            start(id)
        }
        scheduleRetryTimer(wanted)
    }

    private func scheduleRetryTimer(_ wanted: [String]) {
        retryTimer?.invalidate()
        retryTimer = nil
        let now = Date()
        guard isOnline, let next = wanted.compactMap({ retryAfter[$0] }).filter({ $0 > now }).min() else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.pump() }
        }
    }

    private func start(_ id: String) {
        guard let info = trackInfo(id) else { return }
        let part = partURL(id, ext: info.ext)
        let have = Paths.fileSize(part)
        if info.size > 0 && have >= info.size {
            finalize(id, ext: info.ext, part: part)
            return
        }
        let job = DownloadJob(id: id, ext: info.ext, expected: info.size, received: have)
        jobs[id] = job
        setProgress(id, job)
        Task {
            do {
                let range = have > 0 ? "bytes=\(have)-" : nil
                let req = try await drive.authorizedRequest(drive.mediaURL(id), range: range, timeout: 20)
                guard jobs[id] === job, !job.paused else { return }
                let task = session.dataTask(with: req)
                job.task = task
                taskOwner[task.taskIdentifier] = id
                task.resume()
            } catch {
                guard jobs[id] === job else { return }
                jobs[id] = nil
                failed(id)
                pump()
            }
        }
    }

    private func pause(_ job: DownloadJob) {
        job.paused = true
        if let task = job.task {
            task.cancel()
        } else {
            jobs[job.id] = nil
        }
    }

    private func failed(_ id: String) {
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        let delay = min(60, pow(2, Double(min(count, 6))))
        retryAfter[id] = Date().addingTimeInterval(delay)
    }

    // MARK: - 세션 콜백 (메인 큐)

    func received(response: URLResponse, taskID: Int) -> Bool {
        guard let id = taskOwner[taskID], let job = jobs[id] else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        job.status = status
        let part = partURL(id, ext: job.ext)
        switch status {
        case 206:
            if !FileManager.default.fileExists(atPath: part.path) {
                FileManager.default.createFile(atPath: part.path, contents: nil)
            }
            job.handle = try? FileHandle(forWritingTo: part)
            _ = try? job.handle?.seekToEnd()
        case 200:
            // 서버가 이어받기를 무시하고 처음부터 보냄
            FileManager.default.createFile(atPath: part.path, contents: nil)
            job.received = 0
            job.handle = try? FileHandle(forWritingTo: part)
        default:
            return false
        }
        return job.handle != nil
    }

    func received(data: Data, taskID: Int) {
        guard let id = taskOwner[taskID], let job = jobs[id], let handle = job.handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            job.task?.cancel()
            return
        }
        job.received += Int64(data.count)
        setProgress(id, job)
    }

    func completed(taskID: Int, error: Error?) {
        guard let id = taskOwner.removeValue(forKey: taskID), let job = jobs[id] else { return }
        try? job.handle?.close()
        jobs[id] = nil
        if job.paused {
            pump()
            return
        }
        let part = partURL(id, ext: job.ext)
        let size = Paths.fileSize(part)
        let complete = job.expected <= 0 || size >= job.expected
        if error == nil && (job.status == 200 || job.status == 206) && complete {
            finalize(id, ext: job.ext, part: part)
        } else if job.status == 416 && job.expected > 0 && size >= job.expected {
            finalize(id, ext: job.ext, part: part)
        } else {
            if job.status == 416 { try? FileManager.default.removeItem(at: part) }
            if job.status == 401 {
                Task { _ = try? await drive.auth.validToken(forceRefresh: true) }
            }
            failed(id)
        }
        pump()
    }

    // MARK: - 파일

    private func finalURL(_ id: String, ext: String) -> URL {
        Paths.audio.appendingPathComponent("\(id).\(ext.isEmpty ? "mp3" : ext)")
    }

    private func partURL(_ id: String, ext: String) -> URL {
        finalURL(id, ext: ext).appendingPathExtension("part")
    }

    private func finalize(_ id: String, ext: String, part: URL) {
        let final = finalURL(id, ext: ext)
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: part, to: final)
        } catch {
            failed(id)
            return
        }
        let size = Paths.fileSize(final)
        files[id] = final
        sizes[id] = size
        cached.insert(id)
        progress[id] = nil
        failures[id] = nil
        retryAfter[id] = nil
        usedBytes += size
        lastAccess[id] = Date().timeIntervalSince1970
        onCacheChanged(id, final)
        enforceLimit()
        scheduleSave()
    }

    private func removeFile(_ id: String) {
        if let url = files[id] { try? FileManager.default.removeItem(at: url) }
        let hadFile = files.removeValue(forKey: id) != nil
        usedBytes -= sizes.removeValue(forKey: id) ?? 0
        cached.remove(id)
        progress[id] = nil
        lastAccess[id] = nil
        if hadFile { onCacheChanged(id, nil) }
    }

    private func protectedIDs() -> Set<String> {
        var keep = Set(window).union(pinned)
        if settings.offlineAll { keep.formUnion(files.keys) }
        return keep
    }

    /// 오프라인 저장이 아닌 파일이 한도를 넘으면 오래 안 들은 것부터 지운다
    private func enforceLimit() {
        guard let limit = settings.cacheLimitBytes else { return }
        let keep = protectedIDs()
        var total: Int64 = 0
        var candidates: [(id: String, last: Double, size: Int64)] = []
        for (id, size) in sizes where !keep.contains(id) {
            total += size
            candidates.append((id, lastAccess[id] ?? 0, size))
        }
        guard total > limit else { return }
        for c in candidates.sorted(by: { $0.last < $1.last }) {
            if total <= limit { break }
            removeFile(c.id)
            total -= c.size
        }
        scheduleSave()
    }

    private func setProgress(_ id: String, _ job: DownloadJob) {
        guard job.expected > 0 else { return }
        let p = min(1, Double(job.received) / Double(job.expected))
        if progress[id] == nil || p - job.lastReported >= 0.02 || p >= 1 {
            job.lastReported = p
            progress[id] = p
        }
    }

    private func pathChanged(online: Bool, expensive: Bool, signature: String) {
        let changed = signature != pathSignature
        pathSignature = signature
        if isOnline != online { isOnline = online }
        if isExpensive != expensive { isExpensive = expensive }
        guard changed else { return }
        // 망이 끊기거나 바뀌면 걸려 있는 연결을 끊고, 돌아오면 기다리지 않고 바로 이어받기
        for job in jobs.values where !job.paused { pause(job) }
        if online { retryAfter.removeAll() }
        pump()
        onNetworkChange()
    }

    // MARK: - 저장

    private var stateURL: URL { Paths.support.appendingPathComponent("downloads.json") }

    private func loadState() {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(SavedDownloads.self, from: data) {
            pinned = Set(saved.pinned)
            lastAccess = saved.lastAccess
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: Paths.audio, includingPropertiesForKeys: nil)) ?? []
        var total: Int64 = 0
        for url in urls where url.pathExtension != "part" {
            let id = url.deletingPathExtension().lastPathComponent
            let size = Paths.fileSize(url)
            files[id] = url
            sizes[id] = size
            total += size
        }
        cached = Set(files.keys)
        usedBytes = total
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            saveScheduled = false
            let saved = SavedDownloads(pinned: Array(pinned), lastAccess: lastAccess)
            if let data = try? JSONEncoder().encode(saved) {
                try? data.write(to: stateURL, options: .atomic)
            }
        }
    }
}

/// URLSession 콜백을 메인 액터의 DownloadManager로 넘긴다 (delegateQueue = main)
final class SessionDelegate: NSObject, URLSessionDataDelegate {
    weak var owner: DownloadManager?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        let ok = MainActor.assumeIsolated { owner?.received(response: response, taskID: id) ?? false }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        MainActor.assumeIsolated { owner?.received(data: data, taskID: id) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated { owner?.completed(taskID: id, error: error) }
    }
}
