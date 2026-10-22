import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var pickFolder = false
    @State private var confirmClear = false
    @State private var confirmSignOut = false

    private let limits: [(String, Double)] = [("1GB", 1), ("2GB", 2), ("5GB", 5), ("10GB", 10), ("20GB", 20), ("무제한", 0)]

    var body: some View {
        @Bindable var settings = app.settings
        let lib = app.library
        let dl = app.downloads
        Form {
            Section("구글 드라이브") {
                LabeledContent("폴더", value: lib.folderName ?? "-")
                LabeledContent("곡 수", value: "\(lib.trackCount)곡")
                if let last = lib.lastSync {
                    LabeledContent("마지막 동기화", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await lib.sync() }
                } label: {
                    HStack {
                        Text("지금 동기화")
                        if lib.isSyncing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(lib.isSyncing)
                Button("폴더 바꾸기") { pickFolder = true }
            }

            Section {
                Stepper("미리 받을 곡: \(settings.prefetchCount)곡", value: $settings.prefetchCount, in: 1...10)
                    .onChange(of: settings.prefetchCount) { _, _ in app.player.settingsChanged() }
            } header: {
                Text("재생")
            } footer: {
                Text("지금 곡 다음으로 이만큼 미리 받아 둬서, 이동 중에 LTE가 끊겨도 그동안은 계속 재생돼요.")
            }

            Section {
                LabeledContent("사용 중", value: ByteCountFormatter.string(fromByteCount: dl.usedBytes, countStyle: .file))
                Picker("자동 저장 한도", selection: $settings.cacheLimitGB) {
                    ForEach(limits, id: \.1) { item in
                        Text(item.0).tag(item.1)
                    }
                }
                .onChange(of: settings.cacheLimitGB) { _, _ in dl.settingsChanged() }
                Toggle("모든 곡 오프라인 저장", isOn: $settings.offlineAll)
                    .onChange(of: settings.offlineAll) { _, _ in dl.settingsChanged() }
                if settings.offlineAll || !dl.pinned.isEmpty {
                    LabeledContent("저장 남은 곡", value: "\(dl.offlineRemaining)곡")
                }
                Toggle("셀룰러에서도 오프라인 저장", isOn: $settings.offlineOnCellular)
                    .onChange(of: settings.offlineOnCellular) { _, _ in dl.settingsChanged() }
                Toggle("셀룰러에서도 곡 정보 읽기", isOn: $settings.scanOnCellular)
                    .onChange(of: settings.scanOnCellular) { _, _ in lib.networkChanged() }
                Button("자동 저장한 곡 지우기", role: .destructive) { confirmClear = true }
            } header: {
                Text("저장 공간")
            } footer: {
                Text("들은 곡은 한도 안에서 폰에 남겨 둬서 다음엔 데이터를 쓰지 않아요. 오프라인 저장한 곡은 한도와 상관없이 남아요. 곡 정보(제목·앨범·표지)는 기본적으로 와이파이에서만 읽어요.")
            }

            Section {
                Button("로그아웃", role: .destructive) { confirmSignOut = true }
            } footer: {
                Text("버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
            }
        }
        .navigationTitle("설정")
        .sheet(isPresented: $pickFolder) {
            NavigationStack {
                FolderPickerView(parentID: "root", title: "내 드라이브") { pickFolder = false }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { pickFolder = false }
                        }
                    }
            }
        }
        .confirmationDialog("오프라인 저장하지 않은 곡 파일을 지울까요?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("지우기", role: .destructive) { dl.clearCache() }
        }
        .confirmationDialog("로그아웃할까요?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("로그아웃", role: .destructive) { app.signOut() }
        }
    }
}
