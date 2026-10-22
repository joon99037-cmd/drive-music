import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit

private struct SavedPlayer: Codable {
    var queue: [String]
    var original: [String]
    var index: Int
    var time: Double
    var shuffle: Bool
    var repeatMode: RepeatMode
}

/// 대기열·재생 상태·잠금화면 연동. 실제 소리는 GaplessEngine이 낸다
@MainActor @Observable
final class PlayerController: GaplessEngineDelegate {
    private(set) var queue: [QueueEntry] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var durations: [String: Double] = [:]

    @ObservationIgnored private var original: [QueueEntry] = []
    @ObservationIgnored private let snapshot: QueueSnapshot
    @ObservationIgnored private let engine: GaplessEngine
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(library: LibraryStore, downloads: DownloadManager, settings: Settings) {
        self.library = library
        self.downloads = downloads
        self.settings = settings
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        let snap = QueueSnapshot()
        snap.setURLs(downloads.allFiles)
        snapshot = snap
        engine = GaplessEngine(snapshot: snap)
        engine.delegate = self

        setupRemoteCommands()
        observeSession()
        restore()
    }

    var current: Track? {
        guard queue.indices.contains(index) else { return nil }
        return library.track(queue[index].trackID)
    }

    var currentTime: Double { engine.currentTime }

    var currentDuration: Double {
        guard let t = current else { return 0 }
        return durations[t.id] ?? t.duration ?? 0
    }

    var upcoming: [(offset: Int, track: Track)] {
        guard !queue.isEmpty else { return [] }
        return queue.indices.dropFirst(index + 1).compactMap { i -> (offset: Int, track: Track)? in
            guard let track = library.track(queue[i].trackID) else { return nil }
            return (offset: i, track: track)
        }
    }

    // MARK: - 조작

    func play(_ tracks: [Track], startAt start: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        let entries = tracks.map { QueueEntry(trackID: $0.id) }
        original = entries
        shuffle = shuffled
        if shuffled {
            var rest = entries
            let first = rest.remove(at: min(max(0, start), rest.count - 1))
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = entries
            index = min(max(0, start), entries.count - 1)
        }
        loadCurrent(at: 0, play: true)
    }

    func togglePlay() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        isPlaying = true
        engine.setPlaying(true)
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        engine.setPlaying(false)
        updateNowPlaying()
        save()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = index + 1 < queue.count ? index + 1 : 0
        loadCurrent(at: 0, play: isPlaying)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if index > 0 {
            index -= 1
        } else if repeatMode == .all {
            index = queue.count - 1
        }
        loadCurrent(at: 0, play: isPlaying)
    }

    func seek(to time: Double) {
        engine.seek(to: time)
        updateNowPlaying(elapsed: time)
        save(time: time)
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        loadCurrent(at: 0, play: true)
    }

    func toggleShuffle() {
        guard let currentEntry = queue.indices.contains(index) ? queue[index] : nil else {
            shuffle.toggle()
            return
        }
        shuffle.toggle()
        if shuffle {
            let rest = queue.filter { $0.uid != currentEntry.uid }
            queue = [currentEntry] + rest.shuffled()
            index = 0
        } else {
            var restored = original
            let known = Set(original.map(\.uid))
            restored += queue.filter { !known.contains($0.uid) }
            queue = restored
            index = queue.firstIndex(where: { $0.uid == currentEntry.uid }) ?? 0
        }
        queueChanged()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        queueChanged()
    }

    func playNext(_ track: Track) {
        guard !queue.isEmpty else {
            play([track])
            return
        }
        let entry = QueueEntry(trackID: track.id)
        queue.insert(entry, at: index + 1)
        original.append(entry)
        queueChanged()
    }

    func addToQueue(_ track: Track) {
        guard !queue.isEmpty else {
            play([track])
            return
        }
        let entry = QueueEntry(trackID: track.id)
        queue.append(entry)
        original.append(entry)
        queueChanged()
    }

    func removeFromQueue(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let removed = queue.remove(at: i)
        original.removeAll { $0.uid == removed.uid }
        if i < index { index -= 1 }
        queueChanged()
    }

    // MARK: - 내부

    private func loadCurrent(at time: Double, play: Bool) {
        guard queue.indices.contains(index) else { return }
        syncSnapshot()
        updateWindow()
        if play { try? AVAudioSession.sharedInstance().setActive(true) }
        isPlaying = play
        engine.load(queue[index], at: time, play: play)
        updateNowPlaying(elapsed: time)
        save(time: time)
    }

    private func queueChanged() {
        syncSnapshot()
        engine.revalidate()
        updateWindow()
        save()
    }

    private func syncSnapshot() {
        snapshot.update(entries: queue, repeatMode: repeatMode)
    }

    /// 지금 곡 + 다음 몇 곡을 먼저 받도록
    private func updateWindow() {
        guard !queue.isEmpty else {
            downloads.setWindow([])
            return
        }
        var ids: [String] = []
        var i = index
        for _ in 0...max(1, settings.prefetchCount) {
            if i >= queue.count {
                guard repeatMode == .all else { break }
                i = 0
            }
            let id = queue[i].trackID
            if !ids.contains(id) { ids.append(id) }
            i += 1
        }
        downloads.setWindow(ids)
    }

    func cacheChanged(_ trackID: String, _ url: URL?) {
        snapshot.setURL(url, for: trackID)
        if url != nil { engine.kick() }
    }

    func settingsChanged() {
        updateWindow()
    }

    // MARK: - 엔진 알림

    func engineDidStart(uid: String) {
        guard let i = queue.firstIndex(where: { $0.uid == uid }) else { return }
        index = i
        updateWindow()
        updateNowPlaying()
        save()
    }

    func engineDidOpen(trackID: String, duration: Double) {
        durations[trackID] = duration
        library.setDuration(duration, for: trackID)
        if current?.id == trackID { updateNowPlaying() }
    }

    func engineFailedToOpen(trackID: String) {
        // 깨진 파일이면 지우고 다시 받게 한다
        downloads.remove(trackID)
        snapshot.setURL(nil, for: trackID)
    }

    func engineBufferingChanged(_ buffering: Bool) {
        isBuffering = buffering
        updateNowPlaying()
    }

    func engineDidReachEnd() {
        isPlaying = false
        guard !queue.isEmpty else { return }
        index = 0
        loadCurrent(at: 0, play: false)
    }

    // MARK: - 잠금화면·이어폰

    private func updateNowPlaying(elapsed: Double? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.displayAlbum,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed ?? currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying && !isBuffering) ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
        ]
        let duration = currentDuration
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let key = track.artKey, let image = ArtStore.image(key, side: 300) {
            info[MPMediaItemPropertyArtwork] = Self.artwork(image)
        }
        center.nowPlayingInfo = info
    }

    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = e.positionTime
            MainActor.assumeIsolated { self?.seek(to: time) }
            return .success
        }
    }

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // 이어폰을 빼면 멈춤
                if reasonRaw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()
                }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isPlaying {
                engine.interrupted()
                isPlaying = false
                resumeAfterInterruption = true
                updateNowPlaying()
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if resumeAfterInterruption && options.contains(.shouldResume) {
                resume()
            }
            resumeAfterInterruption = false
        @unknown default:
            break
        }
    }

    @ObservationIgnored private var resumeAfterInterruption = false

    // MARK: - 다음 실행 때 이어 듣기

    private var saveURL: URL { Paths.support.appendingPathComponent("player.json") }

    func save(time: Double? = nil) {
        let state = SavedPlayer(
            queue: queue.map(\.trackID),
            original: original.map(\.trackID),
            index: index,
            time: time ?? currentTime,
            shuffle: shuffle,
            repeatMode: repeatMode
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: saveURL, options: .atomic)
        }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: saveURL),
              let state = try? JSONDecoder().decode(SavedPlayer.self, from: data) else { return }
        let ids = state.queue.filter { library.track($0) != nil }
        guard !ids.isEmpty else { return }
        queue = ids.map { QueueEntry(trackID: $0) }
        // 셔플 해제 때 돌아갈 순서: 같은 곡이면 같은 항목을 쓰도록 짝 맞추기
        var pool = queue
        var matched: [QueueEntry] = []
        for id in state.original {
            if let i = pool.firstIndex(where: { $0.trackID == id }) { matched.append(pool.remove(at: i)) }
        }
        original = matched + pool
        shuffle = state.shuffle
        repeatMode = state.repeatMode
        let currentID = state.queue.indices.contains(state.index) ? state.queue[state.index] : nil
        index = currentID.flatMap { id in queue.firstIndex(where: { $0.trackID == id }) } ?? 0
        loadCurrent(at: state.time, play: false)
    }
}
