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
            FolderSourceSettings(coordinator: coordinator)
                .tabItem { Label("來源資料夾", systemImage: "folder") }

            PhotosAlbumSettings(settings: settings, onChange: onChange)
                .tabItem { Label("照片相簿", systemImage: "photo.stack") }

            RemoteSourceSettings(settings: settings, onChange: onChange)
                .tabItem { Label("網路來源", systemImage: "globe") }

            VideoSettings(settings: settings, onVideoToggle: onVideoToggle)
                .tabItem { Label("影片桌布", systemImage: "play.rectangle") }

            RuleSettings(coordinator: coordinator, settings: settings, onChange: onRulesChange)
                .tabItem { Label("狀態規則", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 500)
    }
}

// MARK: - 來源資料夾

/// 資料夾來源本來散在選單列的子選單裡，跟照片相簿／網路來源不在同一個地方。
/// 三種來源既然是同一件事，就放同一頁。
private struct FolderSourceSettings: View {

    @Bindable var coordinator: WallpaperCoordinator

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
                        .padding(.vertical, 2)
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

    @Bindable var settings: AppSettings
    var onVideoToggle: () -> Void

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
                        Text("影片**只在螢幕重新亮起時**（睡醒、螢保結束、解鎖）換一批，"
                             + "最少間隔 30 分鐘，不跟著桌布輪換。關掉開關會把已拷進去的影片清乾淨。")
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

                Divider()

                Text("怎麼開始播").font(.headline)

                step(1, "打開上面的**啟用影片桌布**開關，並在選單列 → 來源資料夾加入一個"
                        + "**裡面有影片**的資料夾。")
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
                        RuleRow(rule: $rule, modes: coordinator.focusModes, onChange: onChange)
                    }
                    .onDelete { offsets in
                        settings.sourceRules.remove(atOffsets: offsets)
                        onChange()
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
}

private struct RuleRow: View {

    @Binding var rule: SourceRule
    var modes: [FocusMode]
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $rule.isEnabled) {
                Text(title).font(.body)
            }
            .onChange(of: rule.isEnabled) { _, _ in onChange() }

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
