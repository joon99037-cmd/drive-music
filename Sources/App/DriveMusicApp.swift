import SwiftUI
import Observation

@main
struct DriveMusicApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.becameActive() }
                    if phase == .background { app.player.save() }
                }
        }
    }
}

@MainActor @Observable
final class AppModel {
    let settings: Settings
    let auth: GoogleAuth
    let drive: DriveAPI
    let downloads: DownloadManager
    let library: LibraryStore
    let player: PlayerController

    @ObservationIgnored private var lastAutoSync = Date.distantPast

    init() {
        settings = Settings()
        auth = GoogleAuth()
        drive = DriveAPI(auth: auth)
        downloads = DownloadManager(drive: drive, settings: settings)
        library = LibraryStore(drive: drive, downloads: downloads, settings: settings)
        player = PlayerController(library: library, downloads: downloads, settings: settings)

        downloads.trackInfo = { [weak library] id in
            guard let t = library?.track(id) else { return nil }
            return (t.size, t.ext)
        }
        downloads.allTrackIDs = { [weak library] in library?.allIDs ?? [] }
        downloads.onNetworkChange = { [weak library] in library?.networkChanged() }
        downloads.onCacheChanged = { [weak player, weak library] id, url in
            player?.cacheChanged(id, url)
            if url != nil { library?.scanLocalIfNeeded(id) }
        }
        downloads.pump()
    }

    /// 앱을 열 때마다(30분 간격) 드라이브와 맞춰 본다
    func becameActive() {
        guard auth.isSignedIn, library.folderID != nil, Date().timeIntervalSince(lastAutoSync) > 1800 else { return }
        lastAutoSync = Date()
        Task { await library.sync() }
    }

    func signOut() {
        player.pause()
        auth.signOut()
    }
}
