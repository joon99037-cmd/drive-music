import SwiftUI

/// 음악이 든 드라이브 폴더 고르기
struct FolderPickerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let parentID: String
    let title: String
    var onPicked: (() -> Void)? = nil

    @State private var folders: [DriveFile] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.red)
            }
            ForEach(folders) { folder in
                NavigationLink {
                    FolderPickerView(parentID: folder.id, title: folder.name, onPicked: onPicked)
                } label: {
                    Label(folder.name, systemImage: "folder.fill")
                }
            }
            if !loading && folders.isEmpty && error == nil {
                Text("하위 폴더가 없어요")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if loading { ProgressView() }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("이 폴더 선택") {
                    app.library.setFolder(id: parentID, name: title)
                    onPicked?()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("음악 파일이 들어 있는 폴더로 들어간 뒤 '이 폴더 선택'을 눌러 주세요. 하위 폴더의 곡도 함께 불러와요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .task {
            do {
                folders = try await app.drive.folders(in: parentID)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}
