import SwiftUI

private func timeText(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - 아래 작은 재생 막대

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    var onOpen: () -> Void

    var body: some View {
        let player = app.player
        if let track = player.current {
            HStack(spacing: 12) {
                ArtworkView(key: track.artKey, size: 44, corner: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(player.isBuffering ? "불러오는 중…" : track.displayArtist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    player.togglePlay()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 40, height: 40)
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 40)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                MiniProgress()
                    .padding(.horizontal, 14)
            }
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }
}

private struct MiniProgress: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let duration = app.player.currentDuration
            let fraction = duration > 0 ? min(1, app.player.currentTime / duration) : 0
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction, height: 2)
            }
            .frame(height: 2)
        }
    }
}

// MARK: - 전체 재생 화면

struct PlayerView: View {
    @Environment(AppModel.self) private var app
    @State private var dragTime: Double?
    @State private var showQueue = false

    var body: some View {
        let player = app.player
        VStack(spacing: 0) {
            if let track = player.current {
                Spacer(minLength: 24)
                ArtworkView(key: track.artKey, corner: 14)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                    .padding(.horizontal, 28)
                    .scaleEffect(player.isPlaying ? 1 : 0.88)
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: player.isPlaying)
                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.displayTitle)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text("\(track.displayArtist) — \(track.displayAlbum)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)

                progress
                    .padding(.horizontal, 28)
                    .padding(.top, 18)

                controls
                    .padding(.top, 12)

                status(track)
                    .frame(height: 22)
                    .padding(.top, 8)

                HStack {
                    Button {
                        player.toggleShuffle()
                    } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    Spacer()
                    Button {
                        player.cycleRepeat()
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    }
                }
                .font(.title3)
                .padding(.horizontal, 44)
                .padding(.vertical, 20)
            } else {
                ContentUnavailableView("재생 중인 곡이 없어요", systemImage: "music.note")
            }
        }
        .foregroundStyle(.primary)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let player = app.player
            let duration = max(player.currentDuration, 1)
            let now = dragTime ?? min(player.currentTime, duration)
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { now }, set: { dragTime = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        if !editing, let t = dragTime {
                            player.seek(to: t)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dragTime = nil }
                        }
                    }
                )
                HStack {
                    Text(timeText(now))
                    Spacer()
                    Text("-" + timeText(max(0, player.currentDuration - now)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        let player = app.player
        return HStack(spacing: 44) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
            }
            Button {
                player.togglePlay()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .frame(width: 64, height: 64)
            }
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
            }
        }
    }

    @ViewBuilder private func status(_ track: Track) -> some View {
        let dl = app.downloads
        if app.player.isBuffering {
            if let p = dl.progress[track.id] {
                Label("받는 중 \(Int(p * 100))%", systemImage: "arrow.down.circle")
            } else if !dl.isOnline {
                Label("연결을 기다리는 중 — 연결되면 바로 이어서 재생해요", systemImage: "wifi.slash")
            } else {
                Label("불러오는 중…", systemImage: "hourglass")
            }
        } else if !dl.isOnline {
            Label("오프라인", systemImage: "wifi.slash")
        }
    }
}

// MARK: - 대기열

struct QueueView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        NavigationStack {
            List {
                if let current = player.current {
                    Section("지금 재생 중") {
                        TrackRow(track: current)
                    }
                }
                Section("다음 곡") {
                    ForEach(player.upcoming, id: \.offset) { item in
                        Button {
                            player.jump(to: item.offset)
                        } label: {
                            TrackRow(track: item.track)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                player.removeFromQueue(at: item.offset)
                            } label: {
                                Label("빼기", systemImage: "minus.circle")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("대기열")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
