import SwiftUI

// MARK: - 노래

struct SongsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    private var filtered: [Track] {
        let all = app.library.tracks
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || $0.displayArtist.localizedCaseInsensitiveContains(q)
                || $0.displayAlbum.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        let list = filtered
        List {
            LibraryStatusRow()
            if !list.isEmpty {
                Button {
                    app.player.play(list, startAt: Int.random(in: 0..<list.count), shuffled: true)
                } label: {
                    Label("셔플 재생", systemImage: "shuffle")
                }
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, track in
                Button {
                    app.player.play(list, startAt: i)
                } label: {
                    TrackRow(track: track)
                }
                .buttonStyle(.plain)
                .trackMenu(track)
            }
        }
        .listStyle(.plain)
        .navigationTitle("노래")
        .searchable(text: $search, prompt: "제목, 아티스트, 앨범")
        .refreshable { await app.library.sync() }
        .overlay {
            if app.library.tracks.isEmpty && !app.library.isSyncing {
                ContentUnavailableView("곡이 없어요", systemImage: "music.note",
                                       description: Text("아래로 당겨 드라이브와 다시 맞춰 보세요"))
            }
        }
    }
}

/// 동기화·태그 읽기 진행 상황
struct LibraryStatusRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let lib = app.library
        if lib.isSyncing {
            HStack(spacing: 8) {
                ProgressView()
                Text("드라이브에서 곡 목록을 불러오는 중…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let error = lib.syncError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
        } else if lib.isScanning && lib.scanTotal > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("곡 정보 읽는 중 \(lib.scanDone)/\(lib.scanTotal)")
                ProgressView(value: Double(lib.scanDone), total: Double(max(lib.scanTotal, 1)))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if !app.downloads.isOnline {
            Label("오프라인 — 받아 둔 곡만 재생돼요", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let track: Track
    var showArt = true
    var number: Int? = nil

    var body: some View {
        let isCurrent = app.player.current?.id == track.id
        HStack(spacing: 12) {
            if let number {
                Text("\(number)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            } else if showArt {
                ArtworkView(key: track.artKey, size: 46, corner: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(number == nil ? "\(track.displayArtist) · \(track.displayAlbum)" : track.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            DownloadBadge(id: track.id)
        }
        .contentShape(Rectangle())
    }
}

struct DownloadBadge: View {
    @Environment(AppModel.self) private var app
    let id: String

    var body: some View {
        let dl = app.downloads
        if let p = dl.progress[id] {
            ProgressView(value: p)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 18)
        } else if dl.cached.contains(id) {
            Image(systemName: dl.isPinned(id) ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    func trackMenu(_ track: Track) -> some View {
        modifier(TrackMenu(track: track))
    }
}

private struct TrackMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    let track: Track

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { app.player.playNext(track) } label: {
                Label("다음에 재생", systemImage: "text.insert")
            }
            Button { app.player.addToQueue(track) } label: {
                Label("대기열 끝에 추가", systemImage: "text.append")
            }
            if app.downloads.pinned.contains(track.id) {
                Button { app.downloads.unpin([track.id]) } label: {
                    Label("오프라인 저장 해제", systemImage: "arrow.down.circle.dotted")
                }
            } else {
                Button { app.downloads.pin([track.id]) } label: {
                    Label("오프라인 저장", systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

// MARK: - 앨범

struct AlbumsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let albums = q.isEmpty ? app.library.albums : app.library.albums.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
        }
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .navigationTitle("앨범")
        .searchable(text: $search, prompt: "앨범, 아티스트")
        .refreshable { await app.library.sync() }
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(key: album.artKey, corner: 10)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            Text(album.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(album.artist)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var app
    let album: Album

    /// 태그가 새로 읽히면 최신 앨범으로
    private var live: Album { app.library.album(album.id) ?? album }

    var body: some View {
        let album = live
        let ids = album.tracks.map(\.id)
        let pinned = ids.allSatisfy { app.downloads.isPinned($0) }
        List {
            VStack(spacing: 12) {
                ArtworkView(key: album.artKey, size: 230, corner: 12)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                VStack(spacing: 4) {
                    Text(album.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(album.artist)
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                    Text([album.year, "\(album.tracks.count)곡"].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                PlayButtons(tracks: album.tracks)
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .padding(.vertical, 8)

            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, track in
                Button {
                    app.player.play(album.tracks, startAt: i)
                } label: {
                    TrackRow(track: track, number: track.trackNo ?? (i + 1))
                }
                .buttonStyle(.plain)
                .trackMenu(track)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if pinned { app.downloads.unpin(ids) } else { app.downloads.pin(ids) }
                } label: {
                    Image(systemName: pinned ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityLabel(pinned ? "오프라인 저장 해제" : "오프라인 저장")
            }
        }
    }
}

struct PlayButtons: View {
    @Environment(AppModel.self) private var app
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                app.player.play(tracks)
            } label: {
                Label("재생", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            Button {
                app.player.play(tracks, startAt: Int.random(in: 0..<max(tracks.count, 1)), shuffled: true)
            } label: {
                Label("셔플", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }
}

// MARK: - 아티스트

struct ArtistsView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let artists = q.isEmpty ? app.library.artists : app.library.artists.filter {
            $0.name.localizedCaseInsensitiveContains(q)
        }
        List(artists) { artist in
            NavigationLink {
                ArtistDetailView(artist: artist)
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(key: artist.albums.first(where: { $0.artKey != nil })?.artKey, size: 46, corner: 23)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(artist.name).lineLimit(1)
                        Text("앨범 \(artist.albums.count) · \(artist.trackCount)곡")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("아티스트")
        .searchable(text: $search, prompt: "아티스트")
        .refreshable { await app.library.sync() }
    }
}

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var app
    let artist: Artist

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        let all = artist.albums.flatMap(\.tracks)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PlayButtons(tracks: all)
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(artist.albums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(artist.name)
    }
}
