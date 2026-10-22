import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if !app.auth.isSignedIn {
            LoginView()
        } else if app.library.folderID == nil {
            NavigationStack {
                FolderPickerView(parentID: "root", title: "내 드라이브")
            }
        } else {
            MainTabs()
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var app
    @State private var showPlayer = false

    var body: some View {
        TabView {
            tab { SongsView() }
                .tabItem { Label("노래", systemImage: "music.note") }
            tab { AlbumsView() }
                .tabItem { Label("앨범", systemImage: "square.stack") }
            tab { ArtistsView() }
                .tabItem { Label("아티스트", systemImage: "music.mic") }
            tab { SettingsView() }
                .tabItem { Label("설정", systemImage: "gearshape") }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
                .presentationDragIndicator(.visible)
        }
    }

    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if app.player.current != nil {
                MiniPlayer { showPlayer = true }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("드라이브 뮤직")
                    .font(.largeTitle.bold())
                Text("구글 드라이브 폴더의 음악을\n끊김 없이 재생해요")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                working = true
                error = nil
                Task {
                    do {
                        try await app.auth.signIn()
                    } catch {
                        self.error = error.localizedDescription
                    }
                    working = false
                }
            } label: {
                HStack {
                    if working { ProgressView().tint(.white) }
                    Text("구글 계정으로 로그인")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(working)
        }
        .padding(24)
    }
}
