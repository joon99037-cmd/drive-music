import Foundation

struct QueueEntry: Codable, Hashable {
    let uid: String
    let trackID: String

    init(trackID: String) {
        self.uid = UUID().uuidString
        self.trackID = trackID
    }
}

enum RepeatMode: Int, Codable {
    case off, all, one
}

/// 재생 스레드가 읽는 대기열 사본. 메인에서 고치고 잠금으로 보호한다
final class QueueSnapshot {
    private let lock = NSLock()
    private var entries: [QueueEntry] = []
    private var indexByUID: [String: Int] = [:]
    private var urls: [String: URL] = [:]
    private var repeatMode: RepeatMode = .off

    func update(entries: [QueueEntry], repeatMode: RepeatMode) {
        lock.lock()
        defer { lock.unlock() }
        self.entries = entries
        self.repeatMode = repeatMode
        indexByUID = [:]
        for (i, e) in entries.enumerated() { indexByUID[e.uid] = i }
    }

    func setURL(_ url: URL?, for trackID: String) {
        lock.lock()
        defer { lock.unlock() }
        urls[trackID] = url
    }

    func setURLs(_ all: [String: URL]) {
        lock.lock()
        defer { lock.unlock() }
        urls = all
    }

    func url(for trackID: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[trackID]
    }

    func entry(uid: String) -> QueueEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = indexByUID[uid] else { return nil }
        return entries[i]
    }

    /// 이 항목 다음에 나올 항목. nil이면 대기열 끝
    func next(after uid: String) -> QueueEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = indexByUID[uid] else { return nil }
        if repeatMode == .one { return entries[i] }
        if i + 1 < entries.count { return entries[i + 1] }
        return repeatMode == .all && !entries.isEmpty ? entries[0] : nil
    }
}
