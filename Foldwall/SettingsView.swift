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
        }
        .frame(width: 520, height: 420)
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
                    Text(keyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("驗證")
                }
            }

            if config.kind == .wallhaven {
                Section {
                    SecureField("API key（選填）", text: $key)
                        .onSubmit(saveKey)
                    Text("公開內容不需要 key。有 key 才能提高速率上限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var keyHint: String {
        switch config.kind {
        case .unsplash: "在 unsplash.com/developers 建立 app 後取得 Access Key。"
        case .pexels: "在 pexels.com/api 申請。"
        case .pixabay: "在 pixabay.com/api/docs 取得。"
        case .flickr: "在 flickr.com/services/apps/create 取得 Key（只用公開搜尋）。"
        case .immich: "Immich → 帳號設定 → API Keys。"
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
