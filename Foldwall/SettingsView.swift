//  SettingsView.swift
//  設定視窗只做一件事：收 API key、伺服器網址、相簿選擇。
//  日常操作仍在選單列——這個視窗不是主介面。

import Photos
import SwiftUI
import FoldwallCore

struct SettingsView: View {
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    var body: some View {
        TabView {
            PhotosAlbumSettings(settings: settings, onChange: onChange)
                .tabItem { Label("照片相簿", systemImage: "photo.stack") }

            RemoteSourceSettings(settings: settings, onChange: onChange)
                .tabItem { Label("網路來源", systemImage: "globe") }

            VideoSettings()
                .tabItem { Label("影片桌布", systemImage: "play.rectangle") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - 照片相簿

private struct PhotosAlbumSettings: View {
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    @State private var albums: [PhotoAlbum] = []
    @State private var status = PhotosAlbumSource.authorizationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch status {
            case .authorized, .limited:
                if albums.isEmpty {
                    ContentUnavailableView("沒有可用的相簿", systemImage: "photo.on.rectangle",
                                           description: Text("「照片」裡沒有含影像的相簿。"))
                } else {
                    List(albums) { album in
                        Toggle(isOn: binding(for: album)) {
                            HStack {
                                Text(album.title)
                                Spacer()
                                Text("\(album.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            case .notDetermined:
                ContentUnavailableView {
                    Label("需要「照片」授權", systemImage: "lock")
                } description: {
                    Text("Foldwall 需要讀取權限才能把相簿當成桌布來源。")
                } actions: {
                    Button("允許存取照片…") {
                        Task {
                            status = await PhotosAlbumSource.requestAuthorization()
                            reload()
                        }
                    }
                }
            default:
                ContentUnavailableView {
                    Label("「照片」存取被拒", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("到 系統設定 → 隱私權與安全性 → 照片 開啟 Foldwall。")
                } actions: {
                    Button("開啟系統設定") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
    }

    private func binding(for album: PhotoAlbum) -> Binding<Bool> {
        Binding(
            get: { settings.photoAlbums.contains(album.id) },
            set: { isOn in
                if isOn { settings.photoAlbums.insert(album.id) }
                else { settings.photoAlbums.remove(album.id) }
                onChange()
            }
        )
    }

    private func reload() {
        status = PhotosAlbumSource.authorizationStatus
        guard status == .authorized || status == .limited else { return }
        albums = PhotosAlbumSource.albums()
    }
}

// MARK: - 影片桌布

/// 影片走的是系統的 Wallpaper 管線，設定散在兩個地方（系統設定 + 本 app 選單），
/// 不講清楚沒人知道怎麼用。這一頁就是把流程攤開。
private struct VideoSettings: View {

    @State private var deployedCount = 0
    @State private var libraryPath = VideoLibrary.documentsURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    HStack {
                        Image(systemName: deployedCount > 0 ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(deployedCount > 0 ? .green : .secondary)
                        if deployedCount > 0 {
                            Text("已備妥 **\(deployedCount)** 支影片")
                        } else {
                            Text("目前沒有影片。加入含 mp4／mov／m4v 的來源資料夾即可。")
                        }
                        Spacer()
                    }
                    .padding(4)
                }

                Text("影片和照片用**同一批來源資料夾**——資料夾裡的影片會自動送進系統的桌布清單，不必另外設定路徑。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                Text("怎麼開始播").font(.headline)

                step(1, "在選單列 → 來源資料夾 → 加入資料夾，選一個**裡面有影片**的資料夾。")
                step(2, "打開 系統設定 → 桌布，往下找到 **Foldwall** 區塊。")
                step(3, "選 **Shuffle All** 就會隨機輪播全部影片；想固定一支就直接點那支。"
                        + "隨機的切換頻率（喚醒時／5 分鐘／每天…）也在同一個畫面選。")
                step(4, "回到選單列，勾 **此螢幕改用影片**。"
                        + "漏掉這步，下一輪靜態蒙太奇會把影片蓋掉。")

                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("打開 系統設定 → 桌布", systemImage: "arrow.up.right.square")
                }

                Divider()

                Text("疑難排解").font(.headline)
                Text("桌布清單裡沒有 Foldwall？先把 app 從 /Applications 啟動一次，系統才會登錄它的 extension。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("在 Finder 顯示影片庫") {
                    NSWorkspace.shared.open(libraryPath)
                }
                .font(.caption)
            }
            .padding()
        }
        .onAppear(perform: refresh)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint.opacity(0.18)))
            Text(.init(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        let videos = libraryPath.appending(path: "videos")
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: videos.path)) ?? []
        deployedCount = entries.count
    }
}

// MARK: - 網路來源

private struct RemoteSourceSettings: View {
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    @State private var selection: RemoteSourceConfig.ID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.remoteSources) { config in
                        HStack {
                            Image(systemName: config.isEnabled ? "circle.fill" : "circle")
                                .font(.system(size: 7))
                                .foregroundStyle(config.isEnabled ? .green : .secondary)
                            Text(config.kind.displayName)
                        }
                        .tag(config.id)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    Menu {
                        ForEach(RemoteSourceKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { add(kind) }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)

                    Button {
                        remove()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)

                    Spacer()
                }
                .padding(4)
            }
            .frame(minWidth: 170, maxWidth: 220)

            Group {
                if let index = settings.remoteSources.firstIndex(where: { $0.id == selection }) {
                    RemoteSourceDetail(
                        config: $settings.remoteSources[index],
                        onChange: onChange
                    )
                    .id(settings.remoteSources[index].id)
                } else {
                    ContentUnavailableView("選一個來源", systemImage: "globe",
                                           description: Text("或用左下角 + 新增。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func add(_ kind: RemoteSourceKind) {
        let config = RemoteSourceConfig(kind: kind)
        settings.remoteSources.append(config)
        selection = config.id
        onChange()
    }

    private func remove() {
        guard let selection,
              let index = settings.remoteSources.firstIndex(where: { $0.id == selection })
        else { return }
        // key 跟著設定一起刪，不要留在 Keychain
        try? KeychainStore.set(nil, for: AppSettings.keychainAccount(for: settings.remoteSources[index]))
        settings.remoteSources.remove(at: index)
        self.selection = nil
        onChange()
    }
}

private struct RemoteSourceDetail: View {
    @Binding var config: RemoteSourceConfig
    var onChange: () -> Void

    @State private var key = ""
    @State private var keyLoaded = false

    var body: some View {
        Form {
            Section {
                Toggle("啟用", isOn: $config.isEnabled)
                    .onChange(of: config.isEnabled) { _, _ in onChange() }
            }

            if config.kind.requiresKey {
                Section {
                    SecureField("API key", text: $key)
                        .onSubmit(saveKey)
                    keyHelp
                } header: {
                    Text("驗證")
                }
            }

            if config.kind == .wallhaven {
                Section {
                    Text("Wallhaven 的公開內容**不需要 key**，直接啟用就能用。")
                        .font(.caption)
                    SecureField("API key（選填，可提高速率上限）", text: $key)
                        .onSubmit(saveKey)
                    keyHelp
                }
            }

            if config.kind.requiresEndpoint {
                Section {
                    TextField(endpointLabel, text: $config.endpoint)
                        .onSubmit(onChange)
                    Text(endpointHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if config.kind.supportsQuery {
                Section {
                    TextField("搜尋關鍵字（選填）", text: $config.query)
                        .onSubmit(onChange)
                    Text("留空則取精選／隨機內容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("儲存") {
                    saveKey()
                    onChange()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !keyLoaded else { return }
            key = KeychainStore.get(AppSettings.keychainAccount(for: config)) ?? ""
            keyLoaded = true
        }
    }

    /// 說明 + 可點的申請連結。key 都是免費的，註冊完當場就給。
    @ViewBuilder
    private var keyHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(keyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = config.kind.keyRequestURL {
                Link(destination: url) {
                    Label(linkTitle, systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
    }

    private var linkTitle: String {
        config.kind == .immich ? "開啟 Immich 說明文件" : "前往申請（免費）"
    }

    private var keyHint: String {
        switch config.kind {
        case .unsplash: "在 Unsplash 建立一個 app，複製它的 Access Key。"
        case .pexels: "填個表單就會當場給你 key。"
        case .pixabay: "登入後，API 文件頁面會直接顯示你的 key。"
        case .flickr: "申請非商業用 key 即可（只用公開搜尋）。"
        case .immich: "在你自己的 Immich：帳號設定 → API Keys → 新增。"
        case .wallhaven: "在 Wallhaven 帳號設定頁面最下方。"
        default: ""
        }
    }

    private var endpointLabel: String {
        config.kind == .immich ? "伺服器網址" : "Feed 網址"
    }

    private var endpointHint: String {
        config.kind == .immich
            ? "例如 https://photos.example.com（可只填主機名）。"
            : "RSS／Atom feed 的網址。"
    }

    private func saveKey() {
        try? KeychainStore.set(key, for: AppSettings.keychainAccount(for: config))
    }
}
