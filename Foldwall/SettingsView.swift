//  SettingsView.swift
//  設定視窗只做一件事：收 API key、伺服器網址、相簿選擇。
//  日常操作仍在選單列——這個視窗不是主介面。

import Photos
import SwiftUI
import FoldwallCore

struct SettingsView: View {
    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var onChange: () -> Void
    var onVideoToggle: () -> Void
    var onRulesChange: () -> Void

    var body: some View {
        TabView {
            SourceSettings(coordinator: coordinator, settings: settings, onChange: onChange)
                .tabItem { Label("來源", systemImage: "tray.full") }

            MontageSettings(coordinator: coordinator, settings: settings)
                .tabItem { Label("蒙太奇桌布", systemImage: "square.grid.2x2") }

            VideoSettings(coordinator: coordinator, settings: settings,
                          onVideoToggle: onVideoToggle,
                          onEngineChange: { coordinator.videoEngineDidChange() })
                .tabItem { Label("影片桌布", systemImage: "play.rectangle") }

            RuleSettings(coordinator: coordinator, settings: settings, onChange: onRulesChange)
                .tabItem { Label("狀態規則", systemImage: "slider.horizontal.3") }

            CacheSettings(coordinator: coordinator)
                .tabItem { Label("快取位置", systemImage: "externaldrive") }

            AboutSettings()
                .tabItem { Label("版本", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 520)
    }
}

// MARK: - 來源

/// 三種來源放同一個分頁。用分段控制切換而不是全部塞在一頁——
/// 網路來源本身是主從式介面，硬擠進同一個捲動區會兩邊都變窄。
private struct SourceSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case folders = "資料夾"
        case albums = "照片授權"
        case remote = "網路"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .folders

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            switch kind {
            case .folders: FolderSourceSettings(coordinator: coordinator, settings: settings)
            case .albums: PhotosAlbumSettings(settings: settings, onChange: onChange)
            case .remote: RemoteSourceSettings(settings: settings, onChange: onChange)
            }
        }
    }
}

// MARK: - 來源資料夾

/// 資料夾來源本來散在選單列的子選單裡，跟照片相簿／網路來源不在同一個地方。
/// 三種來源既然是同一件事，就放同一頁。
private struct FolderSourceSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本機、SMB，以及 Box／pCloud／Dropbox／OneDrive／Google Drive 等雲端硬碟的"
                 + "掛載點——裝了桌面版就是一般資料夾，不需要 OAuth。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if coordinator.folders.isEmpty {
                ContentUnavailableView(
                    "尚未加入資料夾",
                    systemImage: "folder.badge.plus",
                    description: Text("加入一個有照片的資料夾就會開始輪播。")
                )
                .frame(maxHeight: 200)
            } else {
                List {
                    ForEach(coordinator.folders, id: \.self) { folder in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.lastPathComponent)
                                    Text(folder.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                                Button("顯示") { coordinator.revealInFinder(folder) }
                                    .buttonStyle(.borderless)
                                Button("移除") { coordinator.removeFolder(folder) }
                                    .buttonStyle(.borderless)
                            }
                            HStack(spacing: 6) {
                                let usable = FileManager.default.isReadableFile(atPath: folder.path)
                                Image(systemName: usable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(usable ? Color.green : Color.red)
                                Text(usable ? "可讀取" : "讀不到（未掛載或無權限）")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.leading, 2)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Button("加入資料夾…") { Task { await coordinator.addFolders() } }
                Spacer()
                if coordinator.status.isIndexing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("掃描中…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if coordinator.status.poolCount > 0 {
                    Text("池 \(coordinator.status.poolCount) 張")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if coordinator.status.offlineCount > 0 {
                Label("有 \(coordinator.status.offlineCount) 個來源離線或無權限",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("這一頁只管來源設好了沒、讀不讀得到。"
                 + "要拿哪些來源合成蒙太奇、哪些放影片，在「蒙太奇桌布」和「影片桌布」分頁決定。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
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
                    Label("「照片」目前無法存取", systemImage: "exclamationmark.triangle")
                } description: {
                    // Foldwall 沒出現在系統設定清單裡是常見情況：app 要**送出過請求**
                    // 才會被登錄進去。所以這裡先給「再次請求」，不是只叫人去系統設定。
                    Text("狀態：\(PhotosAlbumSource.describe(status))\n\n"
                         + "如果系統設定的「照片」清單裡找不到 Foldwall，代表授權請求還沒送出過——"
                         + "先按下面的「請求授權」。")
                } actions: {
                    Button("請求授權…") {
                        Task {
                            status = await PhotosAlbumSource.requestAuthorization()
                            reload()
                        }
                    }
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
        Log.sources.info("照片相簿分頁：\(PhotosAlbumSource.describe(status), privacy: .public)")
        guard status == .authorized || status == .limited else { return }
        albums = PhotosAlbumSource.albums()
    }
}

// MARK: - 影片桌布

/// 影片走的是系統的 Wallpaper 管線，設定散在兩個地方（系統設定 + 本 app 選單），
/// 不講清楚沒人知道怎麼用。這一頁就是把流程攤開。
private struct VideoSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var onVideoToggle: () -> Void
    var onEngineChange: () -> Void

    /// 只列會產出影片的網路來源。
    private var videoSources: [RemoteSourceConfig] {
        settings.remoteSources.filter { $0.kind.media == .video }
    }

    private func folderBinding(_ folder: URL) -> Binding<Bool> {
        Binding(
            get: { settings.usage(for: folder).contains(.video) },
            set: { isOn in
                var usage = settings.usage(for: folder)
                if isOn { usage.insert(.video) } else { usage.remove(.video) }
                settings.setUsage(usage, for: folder)
                coordinator.folderUsageDidChange()
            }
        )
    }

    private func remoteBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.remoteSources.first { $0.id == id }?.isEnabled ?? false },
            set: { isOn in
                guard let index = settings.remoteSources.firstIndex(where: { $0.id == id })
                else { return }
                settings.remoteSources[index].isEnabled = isOn
                coordinator.folderUsageDidChange()
            }
        )
    }

    @State private var deployedCount = 0
    @State private var libraryPath = VideoLibrary.documentsURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("啟用影片桌布", isOn: $settings.videoWallpaperEnabled)
                            .onChange(of: settings.videoWallpaperEnabled) { _, _ in
                                onVideoToggle()
                                refresh()
                            }
                        Text(.init(Self.budgetExplainer))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("影片在**螢幕睡著時**（螢保啟動、鎖定、休眠）預先換好下一批，"
                             + "最少間隔 30 分鐘，不跟著桌布輪換——拷貝一次可能是好幾百 MB，"
                             + "放在你剛回到電腦前那一刻做會卡。關掉開關會把已拷進去的影片清乾淨。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                GroupBox {
                    HStack {
                        Image(systemName: deployedCount > 0 ? "checkmark.circle.fill" : "info.circle")
                            .foregroundStyle(deployedCount > 0 ? .green : .secondary)
                        if deployedCount > 0 {
                            Text("已備妥 **\(deployedCount)** 支影片")
                        } else if settings.videoWallpaperEnabled {
                            Text("目前沒有影片。加入含 mp4／mov／m4v 的來源資料夾即可。"
                                 + "大型來源要等背景掃描與拷貝跑完。")
                        } else {
                            Text("影片桌布未啟用。打開上面的開關才會把來源資料夾裡的影片送進系統桌布清單。")
                        }
                        Spacer()
                    }
                    .padding(4)
                }

                Text("影片和照片用**同一批來源資料夾**——資料夾裡的影片會自動送進系統的桌布清單，不必另外設定路徑。")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                GroupBox("播放方式") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("引擎", selection: $settings.videoEngine) {
                            ForEach(VideoEngine.allCases, id: \.self) { engine in
                                Text(engine.displayName).tag(engine)
                            }
                        }
                        .onChange(of: settings.videoEngine) { _, _ in onEngineChange() }

                        Text(.init(settings.videoEngine.summary))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if settings.videoEngine == .desktopWindow {
                            Picker("圖層", selection: $settings.desktopVideoLayer) {
                                ForEach(DesktopVideoLayer.allCases, id: \.self) { layer in
                                    Text(layer.displayName).tag(layer)
                                }
                            }
                            .onChange(of: settings.desktopVideoLayer) { _, _ in onEngineChange() }
                        }
                    }
                    .padding(4)
                }
                .disabled(!settings.videoWallpaperEnabled)

                GroupBox("要用哪些來源") {
                    VStack(alignment: .leading, spacing: 6) {
                        if coordinator.folders.isEmpty && videoSources.isEmpty {
                            Text("還沒有任何來源。到「來源」分頁加入。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(coordinator.folders, id: \.self) { folder in
                            Toggle(isOn: folderBinding(folder)) {
                                Label(folder.lastPathComponent, systemImage: "folder")
                            }
                            .toggleStyle(.checkbox)
                        }
                        ForEach(videoSources) { config in
                            Toggle(isOn: remoteBinding(config.id)) {
                                Label(config.displayTitle, systemImage: "globe")
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .font(.callout)
                    .padding(4)
                }
                .disabled(!settings.videoWallpaperEnabled)

                GroupBox("從網址下載") {
                    VideoDownloadBox(service: coordinator.downloadService)
                }
                .disabled(!settings.videoWallpaperEnabled)

                Divider()

                Text("怎麼開始播").font(.headline)

                if settings.videoEngine == .desktopWindow {
                    step(1, "打開上面的**啟用影片桌布**開關，在「來源」分頁加入含影片的資料夾，"
                            + "並在上面勾選要用的來源。")
                    step(2, "回選單列勾 **此螢幕改用影片**。就這樣——不必開系統設定、"
                            + "不會拷貝任何檔案。")
                    Text("桌面視窗**不會出現在鎖屏**。要鎖屏請改用系統桌布 extension。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    step(1, "打開上面的**啟用影片桌布**開關，在「來源」分頁加入含影片的資料夾，"
                            + "並在上面勾選要用的來源。")
                step(2, "打開 系統設定 → 桌布，往下找到 **Foldwall** 區塊。")
                step(3, "選 **Shuffle All** 就會隨機輪播全部影片；想固定一支就直接點那支。"
                        + "隨機的切換頻率（喚醒時／5 分鐘／每天…）也在同一個畫面選。")
                    step(4, "回到選單列，勾 **此螢幕改用影片**。"
                            + "漏掉這步，下一輪靜態蒙太奇會把影片蓋掉。")
                }

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

    /// 拆成常數：直接串在 View builder 裡會讓型別檢查器超時。
    private static let budgetExplainer: String = {
        let perFileMB = VideoBudget.maxFileBytes / (1024 * 1024)
        let rotationMB = VideoBudget.rotationBytes / (1024 * 1024)
        return "沙盒 extension 讀不到 app 的來源資料夾，影片必須**實體拷貝**一份進去。"
            + "來源若是 NAS，那會是幾十 GB——所以預設關閉，而且採**輪替**而非囤積："
            + "一次只帶 1–3 支（視大小，單輪上限 \(rotationMB) MB），下次螢幕亮起再換一批，"
            + "整個片庫照樣輪得到。單檔超過 \(perFileMB) MB 一律不收——"
            + "那是片庫內容，不是桌布循環素材。"
    }()

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
                            Text(config.displayTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
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

    private func runTest() {
        // 存檔再測，否則測到的是舊設定
        saveKey()
        onChange()
        let snapshot = config
        test = .testing
        Task {
            let result = await SourceProbe.test(snapshot)
            if snapshot.id == config.id { test = result }
        }
    }

    private func color(for result: SourceTestResult) -> Color {
        switch result {
        case .passed: .green
        case .empty: .orange
        case .failed: .red
        default: .secondary
        }
    }

    @State private var key = ""
    @State private var keyLoaded = false
    @State private var test: SourceTestResult = .untested

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("測試連線") { runTest() }
                        .disabled(test == .testing)
                    if test == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if test != .untested {
                    Label(test.summary, systemImage: test.symbol)
                        .font(.caption)
                        .foregroundStyle(color(for: test))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("這一頁只確認設定填對、連得上。要不要拿它合成蒙太奇或當影片來源，"
                     + "在「蒙太奇桌布」／「影片桌布」分頁勾選。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

            if config.kind == .rsshub {
                Section {
                    Text("需要**自架的 RSSHub**。官方 rsshub.app 已限制存取"
                         + "（自己標明僅供測試），實測匿名請求直接被擋。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("網址填你的 instance（例：`http://localhost:1200`），"
                         + "關鍵字填路由。三種寫法都吃：\n"
                         + "・`rsshub://pixiv/ranking/day`（Radar 複製來的）\n"
                         + "・`/pixiv/ranking/day`（文件複製來的）\n"
                         + "・完整網址（瀏覽器複製來的，只取路由）\n"
                         + "路由後面可以帶參數，例如 `?limit=10`。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("RSSHub")
                }
            }

            if config.kind == .wallhaven {
                Section {
                    Text("Wallhaven 的公開內容**不需要 key**，直接用就行。")
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

// MARK: - 狀態規則

/// 依系統狀態調整來源。條件成立時把效果聯集起來——「任一條說要停，就停」。
private struct RuleSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if settings.sourceRules.isEmpty {
                ContentUnavailableView(
                    "沒有規則",
                    systemImage: "slider.horizontal.3",
                    description: Text("例如：靠電池時停用網路來源；工作模式時暫停影片桌布。")
                )
                .frame(maxHeight: 180)
            } else {
                List {
                    ForEach($settings.sourceRules) { $rule in
                        RuleRow(
                            rule: $rule,
                            modes: coordinator.focusModes,
                            onChange: onChange,
                            onRemove: { remove(rule.id) }
                        )
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Menu("新增規則") {
                    Button("靠電池時…") { add(.onBattery) }
                    Divider()
                    Button("任何專注模式時…") { add(.anyFocus) }
                    ForEach(coordinator.focusModes) { mode in
                        Button("\(mode.name) 模式時…") { add(.focusMode(mode.id)) }
                    }
                }
                .fixedSize()
                Spacer()
                Text("多條同時成立時，效果會疊加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.focusModes.isEmpty {
                Text("讀不到系統的專注模式清單。macOS 沒有公開 API 可查詢目前是哪個模式，"
                     + "Foldwall 讀的是 ~/Library/DoNotDisturb/DB/——格式若隨系統更新改變，"
                     + "專注模式的規則會靜默失效，其他功能不受影響。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
    }

    private var statusHeader: some View {
        GroupBox {
            HStack(spacing: 8) {
                Image(systemName: coordinator.status.activeEffects.isEmpty
                      ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(coordinator.status.activeEffects.isEmpty
                                     ? Color.secondary : Color.green)
                if let reason = coordinator.status.activeRuleReason {
                    Text("目前生效：\(reason)")
                } else {
                    Text("目前沒有規則生效"
                         + (coordinator.activeFocusModeName.map { "（專注：\($0)）" } ?? ""))
                }
                Spacer()
            }
            .padding(4)
        }
    }

    private func add(_ condition: RuleCondition) {
        settings.sourceRules.append(SourceRule(condition: condition))
        onChange()
    }

    private func remove(_ id: UUID) {
        settings.sourceRules.removeAll { $0.id == id }
        onChange()
    }
}

private struct RuleRow: View {

    @Binding var rule: SourceRule
    var modes: [FocusMode]
    var onChange: () -> Void
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: $rule.isEnabled) {
                    Text(title).font(.body)
                }
                .onChange(of: rule.isEnabled) { _, _ in onChange() }
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移除這條規則")
            }

            HStack(spacing: 12) {
                ForEach(RuleEffect.allCases, id: \.effect.rawValue) { item in
                    Toggle(item.label, isOn: binding(for: item.effect))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            .padding(.leading, 20)
            .disabled(!rule.isEnabled)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch rule.condition {
        case .onBattery: "靠電池時"
        case .focusMode(let id) where id.isEmpty: "任何專注模式時"
        case .focusMode(let id): "\(modes.first { $0.id == id }?.name ?? id) 模式時"
        }
    }

    private func binding(for effect: RuleEffect) -> Binding<Bool> {
        Binding(
            get: { rule.effects.contains(effect) },
            set: { isOn in
                if isOn { rule.effects.insert(effect) } else { rule.effects.remove(effect) }
                onChange()
            }
        )
    }
}

// MARK: - 快取位置

/// 「東西到底放在哪」。使用者要把系統的螢幕保護程式來源指過去時，
/// 不該被迫自己去 ~/Library 底下翻——這裡直接給路徑，可顯示可複製。
private struct CacheSettings: View {

    @Bindable var coordinator: WallpaperCoordinator

    @State private var rows: [(location: CacheLocation, count: Int, bytes: Int64)] = []
    @State private var copied: String?
    @State private var pendingClear: CacheLocation?
    @State private var clearError: String?

    private var locations: [CacheLocation] {
        AppPaths.standard().locations(
            videoContainer: VideoLibrary.documentsURL.appending(path: "videos")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("想讓**螢幕保護程式**播 Foldwall 抓下來的圖？")
                        .font(.callout)
                    Text("系統設定 → 螢幕保護程式 → 選「照片」類的樣式 → 選項 → 來源，"
                         + "把來源指到下面**照片**那一列的路徑（`~/Pictures/Foldwall`）。"
                         + "那是一個彙整資料夾，裡面用硬連結收攏了三個快取裡的所有圖——"
                         + "不佔額外空間，快取更新時會自動同步。Foldwall 沒辦法把自己註冊進"
                         + "那個選單，所以要手動指一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            List(rows, id: \.location.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.location.name)
                        if row.location.isPurgeable {
                            Text("可被系統清除")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(.orange.opacity(0.18)))
                        }
                        Spacer()
                        Text("\(row.count) 個・\(format(row.bytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(row.location.purpose)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(row.location.displayPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button(copied == row.location.id ? "已複製" : "複製路徑") {
                            copy(row.location)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        Button("顯示") { reveal(row.location) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Button("清除") { pendingClear = row.location }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(row.count == 0)
                    }
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)

            Text("兩組都在 ~/Library/Caches 底下，磁碟空間不足時 macOS 會自己刪。"
                 + "Foldwall 會重新下載，但螢幕保護程式那邊會暫時沒圖可播。"
                 + "目前掛在桌面上的桌布放在 Application Support，不會被清掉。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onAppear(perform: reload)
        .confirmationDialog(
            pendingClear.map { "清除「\($0.name)」？" } ?? "",
            isPresented: Binding(get: { pendingClear != nil },
                                 set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible
        ) {
            Button("清除", role: .destructive) {
                if let location = pendingClear { clear(location) }
                pendingClear = nil
            }
            Button("取消", role: .cancel) { pendingClear = nil }
        } message: {
            Text(pendingClear.map(consequence) ?? "")
        }
        .alert("清除失敗", isPresented: Binding(get: { clearError != nil },
                                            set: { if !$0 { clearError = nil } })) {
            Button("好") { clearError = nil }
        } message: {
            Text(clearError ?? "")
        }
    }

    /// 講清楚刪了會怎樣，而不是只問「確定嗎」。
    private func consequence(_ location: CacheLocation) -> String {
        switch location.id {
        case "videos":
            "輪替中的影片會被移除，影片螢幕暫由蒙太奇接管，下次螢幕睡著時再預先拷一批。"
        default:
            "清完**不會立刻重新下載**，等下一個排程輪次自然補回來。"
                + "目前掛在桌面上的桌布不受影響。"
        }
    }

    private func clear(_ location: CacheLocation) {
        do {
            try coordinator.clearCache(location)
        } catch {
            clearError = (error as NSError).localizedDescription
        }
        // container 是背景非同步清的，稍等一下再重新量
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            reload()
        }
    }

    private func reload() {
        // 掃目錄要 20–30ms（實測 373 項）。放在主執行緒上就是開這頁時掉兩格畫面。
        let locations = self.locations
        Task {
            let measured = await Task.detached(priority: .utility) {
                locations.map { location -> (CacheLocation, Int, Int64) in
                    let one = location.measure()
                    return (location, one.count, one.bytes)
                }
            }.value
            rows = measured
        }
    }

    private func copy(_ location: CacheLocation) {
        // 貼進 Finder 的「前往檔案夾」或終端機都要能用 → 給展開後的絕對路徑
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location.url.path, forType: .string)
        copied = location.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == location.id { copied = nil }
        }
    }

    private func reveal(_ location: CacheLocation) {
        try? FileManager.default.createDirectory(at: location.url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(location.url)
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 蒙太奇桌布

/// 靜態管線自己的設定。間隔與後製在選單列也有——那裡是隨手切換的地方，
/// 這裡則把「這些數字實際代表什麼」講清楚。
private struct MontageSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                    Text(poolSummary)
                    Spacer()
                    Button("下一張") { coordinator.next() }
                }
                .padding(4)
            }

            Form {
                Picker("切換間隔", selection: Binding(
                    get: { settings.intervalMinutes },
                    set: { coordinator.setInterval($0) }
                )) {
                    ForEach(Scheduler.intervalOptions, id: \.self) { minutes in
                        Text(Scheduler.intervalLabel(minutes)).tag(minutes)
                    }
                }

                Picker("後製", selection: Binding(
                    get: { settings.effect },
                    set: { coordinator.setEffect($0) }
                )) {
                    ForEach(PostProcess.allCases, id: \.self) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
            }
            .formStyle(.grouped)

            GroupBox("要用哪些來源") {
                VStack(alignment: .leading, spacing: 6) {
                    if coordinator.folders.isEmpty && imageSources.isEmpty
                        && coordinator.albums.isEmpty {
                        Text("還沒有任何來源。到「來源」分頁加入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(coordinator.folders, id: \.self) { folder in
                        Toggle(isOn: folderBinding(folder)) {
                            Label(folder.lastPathComponent, systemImage: "folder")
                        }
                        .toggleStyle(.checkbox)
                    }
                    ForEach(coordinator.albums) { album in
                        Toggle(isOn: albumBinding(album)) {
                            Label("\(album.title)（\(album.count)）", systemImage: "photo.stack")
                        }
                        .toggleStyle(.checkbox)
                    }
                    ForEach(imageSources) { config in
                        Toggle(isOn: remoteBinding(config.id)) {
                            Label(config.displayTitle, systemImage: "globe")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .font(.callout)
                .padding(4)
            }

            GroupBox("每輪抽幾張") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(coordinator.displays, id: \.uuid) { display in
                        let longSide = max(display.canvas.width, display.canvas.height)
                        HStack {
                            Text("\(Int(display.canvas.width))×\(Int(display.canvas.height))")
                                .monospacedDigit()
                            Spacer()
                            Text("\(StillPipeline.pieceCount(longSide: longSide, tier: .full)) 張")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Text("依螢幕長邊決定，每台螢幕各自抽圖、各自合成——同一時間兩台不會是同一張。"
                         + "降載時封頂 6 張。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(4)
            }

            Spacer()
        }
        .padding()
    }

    /// 只列會產出圖的網路來源；Pexels 影片那種歸影片分頁。
    private var imageSources: [RemoteSourceConfig] {
        settings.remoteSources.filter { $0.kind.media == .image }
    }

    private func folderBinding(_ folder: URL) -> Binding<Bool> {
        Binding(
            get: { settings.usage(for: folder).contains(.montage) },
            set: { isOn in
                var usage = settings.usage(for: folder)
                if isOn { usage.insert(.montage) } else { usage.remove(.montage) }
                settings.setUsage(usage, for: folder)
                coordinator.folderUsageDidChange()
            }
        )
    }

    private func albumBinding(_ album: PhotoAlbum) -> Binding<Bool> {
        Binding(
            get: { settings.photoAlbums.contains(album.id) },
            set: { isOn in
                if isOn { settings.photoAlbums.insert(album.id) }
                else { settings.photoAlbums.remove(album.id) }
                coordinator.sourcesDidChange()
            }
        )
    }

    private func remoteBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.remoteSources.first { $0.id == id }?.isEnabled ?? false },
            set: { isOn in
                guard let index = settings.remoteSources.firstIndex(where: { $0.id == id })
                else { return }
                settings.remoteSources[index].isEnabled = isOn
                coordinator.sourcesDidChange()
            }
        )
    }

    private var poolSummary: String {
        let status = coordinator.status
        if status.isIndexing && status.poolCount == 0 { return "正在掃描資料夾…" }
        var parts = ["池 \(status.poolCount) 張"]
        if status.remoteCount > 0 { parts.append("網路 \(status.remoteCount)") }
        if status.photosCount > 0 { parts.append("相簿 \(status.photosCount)") }
        if status.isIndexing { parts.append("掃描中") }
        return parts.joined(separator: "・")
    }

}

// MARK: - 版本

private struct AboutSettings: View {

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short)（build \(build)）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Foldwall").font(.title2.bold())
                    Text(version).foregroundStyle(.secondary).monospacedDigit()
                    Text("macOS 26+・Apple Silicon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Text("從資料夾、照片相簿與免 OAuth 的網路來源隨機合成蒙太奇桌布，"
                 + "並支援影片桌布（桌面＋鎖屏）。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("授權") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Foldwall 以 MIT 授權釋出。")
                        .font(.caption)
                    Text("影片桌布 extension fork 自 **Phosphene**（MIT），"
                         + "授權原文隨原始碼一起保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("照片由 Unsplash／Pexels／Pixabay／Wallhaven 等來源提供，"
                         + "各自的使用規範以該站條款為準。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            HStack {
                Link("原始碼（GitHub）", destination: URL(string: "https://github.com/gixiphy/foldwall")!)
                Spacer()
            }
            .font(.callout)

            Spacer()
        }
        .padding()
    }
}

// MARK: - 從網址下載

/// Foldwall **不做**串流解析。這裡呼叫的是使用者自己安裝的 yt-dlp，
/// 抽取那一段由那個工具負責，也由使用者自己決定要對哪個站用。
private struct VideoDownloadBox: View {

    @Bindable var service: VideoDownloadService
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if service.toolURL == nil {
                Label("需要 yt-dlp", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("Foldwall 不自己解析串流。安裝後即可使用：`brew install yt-dlp`\n"
                     + "（同時裝 ffmpeg 可以支援更多格式）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    TextField("影片網址", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { service.download(url) }
                    Button("下載") { service.download(url) }
                        .disabled(url.isEmpty || service.state == .running)
                    if service.state == .running {
                        ProgressView().controlSize(.small)
                    }
                }
                if !service.state.summary.isEmpty {
                    Text(service.state.summary)
                        .font(.caption)
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("存到 `~/Movies/Foldwall`，自動成為影片來源。"
                     + "最高 \(VideoDownloadTool.maximumHeight)p——桌布不需要 4K，"
                     + "檔案大好幾倍又更吃電。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(4)
    }

    private var color: Color {
        switch service.state {
        case .finished: .green
        case .failed: .red
        default: .secondary
        }
    }
}
