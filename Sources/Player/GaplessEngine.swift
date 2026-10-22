import AVFoundation

@MainActor
protocol GaplessEngineDelegate: AnyObject {
    func engineDidStart(uid: String)
    func engineDidOpen(trackID: String, duration: Double)
    func engineFailedToOpen(trackID: String)
    func engineBufferingChanged(_ buffering: Bool)
    func engineDidReachEnd()
}

private enum EngineError: Error {
    case format
}

/// 한 곡의 파일을 조각내어 읽고 출력 포맷(44.1kHz 스테레오 float)으로 맞춘다
private final class Feeder {
    let entry: QueueEntry
    let feedID: Int
    let file: AVAudioFile
    let out: AVAudioFormat
    let converter: AVAudioConverter?
    let readBuffer: AVAudioPCMBuffer
    let sampleRate: Double

    init(entry: QueueEntry, feedID: Int, url: URL, start: Double, out: AVAudioFormat, chunk: AVAudioFrameCount) throws {
        self.entry = entry
        self.feedID = feedID
        self.out = out
        file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        sampleRate = inFormat.sampleRate
        if inFormat.sampleRate != out.sampleRate {
            guard let mid = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: inFormat.channelCount),
                  let conv = AVAudioConverter(from: inFormat, to: mid) else { throw EngineError.format }
            converter = conv
        } else {
            converter = nil
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw EngineError.format }
        readBuffer = buffer
        let startFrame = AVAudioFramePosition(start * sampleRate)
        if startFrame > 0 && startFrame < file.length {
            file.framePosition = startFrame
        }
    }

    var duration: Double { Double(file.length) / sampleRate }

    /// 다음 조각과 그 조각이 곡 안에서 시작하는 위치(초). 곡 끝이면 nil
    func next() -> (buffer: AVAudioPCMBuffer, time: Double)? {
        let time = Double(file.framePosition) / sampleRate
        do {
            try file.read(into: readBuffer, frameCount: readBuffer.frameCapacity)
        } catch {
            return nil
        }
        guard readBuffer.frameLength > 0 else { return nil }
        var source = readBuffer
        if let converter {
            guard let converted = convert(readBuffer, with: converter) else { return nil }
            source = converted
        }
        guard let output = toOutput(source) else { return nil }
        return (output, time)
    }

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }

    /// 모노는 양쪽으로 복사, 스테레오는 그대로 새 버퍼에 (읽기 버퍼는 다시 쓰므로 반드시 복사)
    private func toOutput(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = src.frameLength
        guard let dst = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: max(frames, 1)),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = frames
        let channels = Int(src.format.channelCount)
        let bytes = Int(frames) * MemoryLayout<Float>.size
        memcpy(d[0], s[0], bytes)
        memcpy(d[1], s[channels > 1 ? 1 : 0], bytes)
        return dst
    }
}

/// AVAudioEngine 위에서 곡들을 한 줄로 이어 붙여 재생한다.
/// 다음 곡을 지금 곡 끝나기 몇 초 전부터 같은 플레이어 노드에 이어서 예약하므로 곡 사이에 틈이 없다.
/// 상태는 모두 전용 큐(q)에서만 만진다
final class GaplessEngine {
    weak var delegate: GaplessEngineDelegate?

    private enum Cursor {
        case idle
        case want(QueueEntry, Double)      // 이 곡을 이 위치부터 (파일이 아직 없을 수도)
        case feeding(Feeder)
        case nextAfter(QueueEntry)         // 이 곡을 다 넣었으니 다음 곡으로
        case ended
    }

    private struct Segment {
        let entry: QueueEntry
        let feedID: Int
        let start: AVAudioFramePosition    // 플레이어 시간축에서 시작 샘플
        let frames: AVAudioFramePosition
        let time: Double                   // 곡 안에서 이 조각의 시작 위치(초)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let q = DispatchQueue(label: "drivemusic.engine", qos: .userInitiated)
    private let snapshot: QueueSnapshot
    private let chunk: AVAudioFrameCount = 16_384     // 약 0.37초
    private let ahead = 10                            // 미리 예약해 둘 조각 수 (약 3.7초)
    private var timer: DispatchSourceTimer?

    private var cursor: Cursor = .idle
    private var segments: [Segment] = []
    private var timelineEnd: AVAudioFramePosition = 0
    private var inFlight = 0
    private var generation = 0
    private var feedCounter = 0
    private var wantPlaying = false
    private var lastSample: AVAudioFramePosition = 0
    private var needsRebuild = false
    private var reportedKey = ""
    private var buffering = false
    private var endReported = false

    init(snapshot: QueueSnapshot) {
        self.snapshot = snapshot
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.q.async { self.configurationChanged() }
        }

        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - 바깥에서 부르는 것 (아무 스레드)

    func load(_ entry: QueueEntry, at time: Double, play: Bool) {
        q.async { [self] in
            resetStream()
            cursor = .want(entry, max(0, time))
            wantPlaying = play
            pump()
            if play { startOutput() } else { stopOutput() }
            updateBuffering()
        }
    }

    func setPlaying(_ on: Bool) {
        q.async { [self] in
            if on == wantPlaying && (!on || engine.isRunning) { return }
            if on {
                wantPlaying = true
                startOutput()
            } else {
                stopOutput()
                wantPlaying = false
            }
            updateBuffering()
        }
    }

    func seek(to time: Double) {
        q.async { [self] in
            guard let pos = position() else { return }
            resetStream()
            cursor = .want(pos.entry, max(0, time))
            pump()
            if wantPlaying { startOutput() }
            updateBuffering()
        }
    }

    /// 새 파일이 받아졌을 때
    func kick() {
        q.async { [self] in
            pump()
            updateBuffering()
        }
    }

    /// 대기열 순서·반복 모드가 바뀌었을 때
    func revalidate() {
        q.async { [self] in revalidateLocked() }
    }

    /// 전화 등으로 시스템이 소리를 끊었을 때
    func interrupted() {
        q.async { [self] in
            _ = currentSample()
            wantPlaying = false
            needsRebuild = true
            updateBuffering()
        }
    }

    var currentTime: Double {
        q.sync { position()?.time ?? 0 }
    }

    // MARK: - 내부 (q에서만)

    private func resetStream() {
        generation += 1
        player.stop()
        segments.removeAll()
        timelineEnd = 0
        inFlight = 0
        lastSample = 0
        cursor = .idle
        endReported = false
    }

    private func startOutput() {
        if needsRebuild {
            needsRebuild = false
            rebuild()
            return
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                needsRebuild = true
                return
            }
        }
        player.play()
    }

    private func stopOutput() {
        _ = currentSample()
        guard engine.isRunning else { return }
        player.pause()
        engine.pause()
    }

    /// 출력 장치가 바뀌었거나 끊겼다 돌아온 뒤: 지금 위치에서 처음부터 다시 짠다
    private func rebuild() {
        let pos = position()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        if let pos {
            resetStream()
            cursor = .want(pos.entry, pos.time)
            pump()
        }
        if wantPlaying { startOutput() }
    }

    private func configurationChanged() {
        needsRebuild = true
        if wantPlaying { startOutput() }
    }

    private func nodeSample() -> AVAudioFramePosition? {
        guard engine.isRunning,
              let nodeTime = player.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return max(0, playerTime.sampleTime)
    }

    private func currentSample() -> AVAudioFramePosition {
        if wantPlaying, let s = nodeSample() { lastSample = s }
        return lastSample
    }

    private func playingSegment(at s: AVAudioFramePosition) -> Segment? {
        var found: Segment?
        for seg in segments {
            if seg.start <= s { found = seg } else { break }
        }
        return found ?? segments.first
    }

    private func position() -> (entry: QueueEntry, time: Double)? {
        let s = currentSample()
        if inFlight == 0, case .want(let entry, let time) = cursor {
            return (entry, time)
        }
        guard let seg = playingSegment(at: s) else {
            if case .want(let entry, let time) = cursor { return (entry, time) }
            return nil
        }
        let offset = Double(min(max(0, s - seg.start), seg.frames)) / format.sampleRate
        return (seg.entry, seg.time + offset)
    }

    private func pump() {
        var steps = 0
        while inFlight < ahead && steps < 64 {
            steps += 1
            switch cursor {
            case .idle, .ended:
                checkEnd()
                return
            case .want(let entry, let time):
                guard let url = snapshot.url(for: entry.trackID) else { return }   // 아직 받는 중
                feedCounter += 1
                do {
                    let feeder = try Feeder(entry: entry, feedID: feedCounter, url: url, start: time, out: format, chunk: chunk)
                    cursor = .feeding(feeder)
                    let duration = feeder.duration
                    onMain { $0.engineDidOpen(trackID: entry.trackID, duration: duration) }
                } catch {
                    onMain { $0.engineFailedToOpen(trackID: entry.trackID) }
                    cursor = .nextAfter(entry)
                }
            case .nextAfter(let entry):
                if let next = snapshot.next(after: entry.uid) {
                    cursor = .want(next, 0)
                } else {
                    cursor = .ended
                }
            case .feeding(let feeder):
                if let piece = feeder.next() {
                    schedule(piece.buffer, entry: feeder.entry, feedID: feeder.feedID, time: piece.time)
                } else {
                    cursor = .nextAfter(feeder.entry)
                }
            }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, entry: QueueEntry, feedID: Int, time: Double) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        guard frames > 0 else { return }
        var start = timelineEnd
        if inFlight == 0 { start = max(timelineEnd, currentSample()) }
        segments.append(Segment(entry: entry, feedID: feedID, start: start, frames: frames, time: time))
        timelineEnd = start + frames
        inFlight += 1
        let token = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                guard self.generation == token else { return }
                self.inFlight -= 1
                self.pump()
                self.checkEnd()
                self.updateBuffering()
            }
        }
    }

    private func checkEnd() {
        guard case .ended = cursor, inFlight == 0, !endReported else { return }
        endReported = true
        stopOutput()
        wantPlaying = false
        updateBuffering()
        onMain { $0.engineDidReachEnd() }
    }

    private func updateBuffering() {
        var waiting = false
        if wantPlaying && inFlight == 0, case .want = cursor { waiting = true }
        if waiting != buffering {
            buffering = waiting
            onMain { $0.engineBufferingChanged(waiting) }
        }
    }

    private func tick() {
        guard wantPlaying else { return }
        let s = currentSample()
        while segments.count > 1, segments[1].start <= s { segments.removeFirst() }

        var key = ""
        var uid: String?
        if inFlight == 0, case .want(let entry, _) = cursor {
            key = "want-\(entry.uid)"
            uid = entry.uid
        } else if let seg = segments.first, seg.start <= s {
            key = "feed-\(seg.feedID)"
            uid = seg.entry.uid
        }
        if let uid, key != reportedKey {
            reportedKey = key
            onMain { $0.engineDidStart(uid: uid) }
        }
        updateBuffering()
    }

    private func revalidateLocked() {
        if case .ended = cursor {
            if !endReported, let last = segments.last?.entry, let next = snapshot.next(after: last.uid) {
                cursor = .want(next, 0)
                pump()
            }
            return
        }
        let s = currentSample()
        guard let playing = playingSegment(at: s) else {
            pump()
            return
        }
        // 지금 곡 뒤로 이미 예약해 둔 곡 순서가 바뀐 대기열과 맞는지 확인
        var chain: [QueueEntry] = [playing.entry]
        var lastFeed = playing.feedID
        for seg in segments where seg.start > playing.start && seg.feedID != lastFeed {
            chain.append(seg.entry)
            lastFeed = seg.feedID
        }
        if case .want(let entry, _) = cursor { chain.append(entry) }

        var valid = true
        for i in 1..<chain.count where snapshot.next(after: chain[i - 1].uid)?.uid != chain[i].uid {
            valid = false
            break
        }
        if valid {
            pump()
            return
        }
        let time = playing.time + Double(min(max(0, s - playing.start), playing.frames)) / format.sampleRate
        resetStream()
        cursor = .want(playing.entry, time)
        pump()
        if wantPlaying { startOutput() }
        updateBuffering()
    }

    private func onMain(_ body: @escaping @MainActor (GaplessEngineDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let delegate = self?.delegate else { return }
                body(delegate)
            }
        }
    }
}
