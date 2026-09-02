//  SettingsView.swift
//  設定視窗只做一件事：收 API key、伺服器網址、相簿選擇。
//  日常操作仍在選單列——這個視窗不是主介面。

import Photos
import SwiftUI
import FoldwallCore

struct SettingsView: View {
    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var translator: UITranslator
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

            BackupSettings(coordinator: coordinator, settings: settings)
                .tabItem { Label("備份", systemImage: "icloud") }

            LanguageSettings(translator: translator)
                .tabItem { Label("語言", systemImage: "globe") }

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

    /// rawValue 是**識別碼**，不是顯示文字：兩者黏在一起的話，切一次語言
    /// 就等於換一組 id，Picker 的 selection 會對不上而跳回第一項。
    private enum Kind: String, CaseIterable, Identifiable {
        case folders, albums, remote
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .folders: "資料夾"
            case .albums: "照片授權"
            case .remote: "網路"
            }
        }
    }

    @State private var kind: Kind = .folders

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            Divider()

            switch kind {
            case .folders: FolderSourceSettings(coordinator: coordinator, settings: settings)
            case .albums: PhotosAlbumSettings(settings: settings, onChange: onChange)
            case .remote:
                RemoteSourceSettings(coordinator: coordinator, settings: settings,
                                     onChange: onChange)
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

    private struct Source: Identifiable {
        var url: URL
        var isReadable: Bool
        var id: URL { url }
    }

    /// 讀得到的 ＋ 讀不到的，讀不到的排在後面。
    ///
    /// 讀不到的也要列出來：它們仍然是設定裡的來源，不列的話使用者連移除都按不到。
    /// 可讀性**不在這裡量**：coordinator 每輪 refresh 解析書籤時已經分好了，
    /// 這裡再對每個路徑探一次，等於為了畫一顆紅點又去戳一顆沒掛載的網路磁碟。
    private var sources: [Source] {
        coordinator.folders.map { Source(url: $0, isReadable: true) }
            + coordinator.offlineFolders.map { Source(url: $0, isReadable: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("""
                本機、SMB，以及 Box／pCloud／Dropbox／OneDrive／Google Drive \
                等雲端硬碟的掛載點——裝了桌面版就是一般資料夾，不需要 OAuth。
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sources.isEmpty {
                ContentUnavailableView(
                    "尚未加入資料夾",
                    systemImage: "folder.badge.plus",
                    description: Text("加入一個有照片的資料夾就會開始輪播。")
                )
                .frame(maxHeight: 200)
            } else {
                List {
                    ForEach(sources) { source in
                        let folder = source.url
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
                                let usable = source.isReadable
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

            Text("""
                這一頁只管來源設好了沒、讀不讀得到。要拿哪些來源合成蒙太奇、哪些放影片，\
                在「蒙太奇桌布」和「影片桌布」分頁決定。
                """)
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
                    Text("""
                        狀態：\(PhotosAlbumSource.describe(status))\n\n如果系統設定的「照片」\
                        清單裡找不到 Foldwall，代表授權請求還沒送出過——先按下面的「請求授權」。
                        """)
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
        // 走遍整個照片圖庫（十萬張要好幾秒），跟 coordinator.reloadAlbums 一樣放背景，
        // 別讓開這個分頁的那一刻整個視窗凍住。
        Task {
            albums = await Task.detached(priority: .utility) {
                PhotosAlbumSource.albums()
            }.value
        }
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

    private func playlistBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { settings.playlistSources.first { $0.id == id }?.isEnabled ?? false },
            set: { isOn in
                guard let index = settings.playlistSources.firstIndex(where: { $0.id == id })
                else { return }
                settings.playlistSources[index].isEnabled = isOn
                coordinator.folderUsageDidChange()
            }
        )
    }

    @State private var libraryPath = VideoLibrary.documentsURL

    /// 由 coordinator 公布，不是自己去數目錄——這扇窗開著的時候背景還在拷，
    /// 自己數一次就永遠停在開窗那一刻（實測開著窗看到「目前沒有影片」，
    /// 而 container 裡其實已經有三支）。
    private var deployedCount: Int { coordinator.status.deployedVideoCount }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sourceColumn
                .frame(width: 232)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    enableBox
                    statusBox
                    playbackBox
                    Divider()
                    howToStart
                    Divider()
                    troubleshooting
                }
                .padding()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 左欄：來源

    /// 跟蒙太奇分頁同一個結構：來源固定在左欄自己捲，右欄放開關與說明。
    /// 視窗高度是寫死的 520，來源多起來塞在同一根 VStack 裡會捲不到。
    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("要用哪些來源")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Text("和蒙太奇共用同一批來源資料夾，這裡只決定哪些拿來放影片。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if coordinator.folders.isEmpty && videoSources.isEmpty
                        && settings.playlistSources.isEmpty {
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
                    // 片單也是影片來源。少了這段，加了片單的人在這頁看不到它，
                    // 只能從「來源」分頁猜它到底有沒有被用到。
                    ForEach(settings.playlistSources) { source in
                        Toggle(isOn: playlistBinding(source.id)) {
                            Label(source.displayTitle,
                                  systemImage: "list.and.film")
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .disabled(!settings.videoWallpaperEnabled)
        }
    }

    // MARK: - 右欄

    private var enableBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("啟用影片桌布", isOn: $settings.videoWallpaperEnabled)
                    .onChange(of: settings.videoWallpaperEnabled) { _, _ in
                        onVideoToggle()
                    }
                Text(Self.markdown(Self.budgetExplainer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.sleepExplainer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var statusBox: some View {
        GroupBox {
            HStack(alignment: .top) {
                Image(systemName: deployedCount > 0 ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(deployedCount > 0 ? .green : .secondary)
                if deployedCount > 0 {
                    Text("已備妥 **\(deployedCount)** 支影片")
                } else if settings.videoWallpaperEnabled {
                    Text("""
                        目前沒有影片。加入含 mp4／mov／m4v 的來源資料夾即可。\
                        大型來源要等背景掃描與拷貝跑完。
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("""
                        影片桌布未啟用。\
                        打開上面的開關才會把來源資料夾裡的影片送進系統桌布清單。
                        """)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }

    /// 與蒙太奇分頁的控制格同構：標籤靠左、控制項靠右。
    private var playbackBox: some View {
        GroupBox("播放方式") {
            VStack(alignment: .leading, spacing: 10) {
                controlRow("引擎") {
                    Picker("", selection: $settings.videoEngine) {
                        ForEach(VideoEngine.allCases, id: \.self) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .onChange(of: settings.videoEngine) { _, _ in onEngineChange() }
                }

                // 縮放兩條引擎都吃，所以不在下面那個 if 裡面。
                controlRow("縮放") {
                    Picker("", selection: $settings.videoScaleMode) {
                        ForEach(VideoScaleMode.allCases, id: \.self) { scale in
                            Text(scale.displayName).tag(scale)
                        }
                    }
                    .onChange(of: settings.videoScaleMode) { _, _ in
                        coordinator.videoScaleModeDidChange()
                    }
                }

                Text(settings.videoScaleMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.videoEngine == .desktopWindow {
                    controlRow("圖層") {
                        Picker("", selection: $settings.desktopVideoLayer) {
                            ForEach(DesktopVideoLayer.allCases, id: \.self) { layer in
                                Text(layer.displayName).tag(layer)
                            }
                        }
                        .onChange(of: settings.desktopVideoLayer) { _, _ in onEngineChange() }
                    }

                    controlRow("播完之後") {
                        Picker("", selection: $settings.videoPlaybackMode) {
                            ForEach(VideoPlaybackMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .onChange(of: settings.videoPlaybackMode) { _, _ in
                            coordinator.videoPlaybackModeDidChange()
                        }
                    }

                    Text(settings.videoPlaybackMode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Self.extensionRotationNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("下一片影片") { coordinator.nextVideo() }
                    Text("選單列也有，⇧⌘N")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                forceRotationRow

                Text(Self.markdown(settings.videoEngine.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .disabled(!settings.videoWallpaperEnabled)
    }

    /// 「下一片影片」是在當下這份池裡往前一支；這個是把池換掉再整批重抽。
    /// 兩條引擎的「池」不是同一回事，忙碌狀態與說明都跟著引擎走（見 forceVideoRotation）。
    ///
    /// 拆成獨立屬性：直接串進 playbackBox 會讓型別檢查器超時（同 budgetExplainer）。
    @ViewBuilder
    private var forceRotationRow: some View {
        HStack(spacing: 8) {
            Button("強制更換片源") { coordinator.forceVideoRotation() }
                .disabled(isRotating)
            if isRotating {
                ProgressView().controlSize(.small)
                Text(settings.videoEngine.needsDeployment ? "拷貝中…" : "掃描中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(rotationHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// extension 那條在拷貝，桌面視窗那條在重掃——都是「按了、還沒好」。
    private var isRotating: Bool {
        settings.videoEngine.needsDeployment
            ? coordinator.status.isDeployingVideos
            : coordinator.status.isIndexing
    }

    private var rotationHint: String {
        settings.videoEngine.needsDeployment
            ? String(localized: "不等螢幕睡著，現在就換一批進 extension")
            : String(localized: "重掃來源資料夾，然後整批重抽——剛丟進來的新片會在這時候出現")
    }

    /// 標籤靠左、控制項靠右——與蒙太奇分頁同一條右緣。
    private func controlRow<Control: View>(
        _ label: LocalizedStringKey, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .fixedSize()
        }
    }

    @ViewBuilder
    private var howToStart: some View {
        Text("怎麼開始播").font(.headline)

        if settings.videoEngine == .desktopWindow {
            step(1, """
                打開上面的**啟用影片桌布**開關，在「來源」分頁加入含影片的資料夾，\
                並在左欄勾選要用的來源。
                """)
            step(2, "回選單列勾 **此螢幕改用影片**。就這樣——不必開系統設定、不會拷貝任何檔案。")
            Text("桌面視窗**不會出現在鎖屏**。要鎖屏請改用系統桌布 extension。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            step(1, """
                打開上面的**啟用影片桌布**開關，在「來源」分頁加入含影片的資料夾，\
                並在左欄勾選要用的來源。
                """)
            step(2, "打開 系統設定 → 桌布，往下找到 **Foldwall** 區塊。")
            step(3, """
                選 **Shuffle All** 就會隨機輪播全部影片；想固定一支就直接點那支。\
                隨機的切換頻率（喚醒時／5 分鐘／每天…）也在同一個畫面選。
                """)
            step(4, "回到選單列，勾 **此螢幕改用影片**。漏掉這步，下一輪靜態蒙太奇會把影片蓋掉。")
        }

        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label("打開 系統設定 → 桌布", systemImage: "arrow.up.right.square")
        }
    }

    @ViewBuilder
    private var troubleshooting: some View {
        Text("疑難排解").font(.headline)
        Text("""
            桌布清單裡沒有 Foldwall？先把 app 從 /Applications 啟動一次，系統才會登錄它的 \
            extension。
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Button("在 Finder 顯示影片庫") {
            NSWorkspace.shared.open(libraryPath)
        }
        .font(.caption)
    }

    /// Markdown 得先解析成 AttributedString 再交給 Text。
    /// `Text(.init(someString))` 只會把 `**` 吃掉不上粗體——那條路是查本地化鍵，
    /// 非字面量的 key 查不到、退回原字串時屬性就掉了。
    private static func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    /// 系統 extension 那條的輪替不歸這一頁管，講清楚它在哪裡設。
    ///
    /// 這三段從 `static let` 改成 computed：`static let` 在第一次取用時求值一次，
    /// 之後整個 process 都用那份結果——查表也一起被凍住，語言就再也換不掉。
    private static var extensionRotationNote: AttributedString {
        markdown(String(localized: """
            系統 extension 的輪替由**系統設定 → 桌布**決定：選 **Shuffle All** 才會輪播，\
            並在它的「Change Video」選單挑頻率（含**每播完一支**）。\
            選了固定某一支就是單片循環。「下一片影片」在那裡也有效。
            """))
    }

    private static var sleepExplainer: AttributedString {
        markdown(String(localized: """
            影片在**螢幕睡著時**（螢保啟動、鎖定、休眠）預先換好下一批，最少間隔 30 分鐘，\
            不跟著桌布輪換——拷貝一次可能是好幾百 MB，放在你剛回到電腦前那一刻做會卡。\
            等不及就按下面的**強制更換片源**。關掉開關會把已拷進去的影片清乾淨。
            """))
    }

    /// 拆成獨立屬性：直接串在 View builder 裡會讓型別檢查器超時。
    private static var budgetExplainer: String {
        let perFileGB = VideoBudget.maxFileBytes / (1024 * 1024 * 1024)
        let rotationGB = VideoBudget.rotationBytes / (1024 * 1024 * 1024)
        let perRoundMB = rotationGB * 1024 / 4
        return String(localized: """
            沙盒 extension 讀不到 app 的來源資料夾，影片必須**實體拷貝**一份進去。來源若是 \
            NAS，那會是幾十 GB——所以預設關閉，而且採**輪替**而非囤積：\
            一次帶到**填滿 \(rotationGB) GB** 為止（幾支視大小而定）。下次螢幕亮起換一批，\
            但**只換四分之一**——重疊的部分不必重拷，每輪從來源搬動的量因此是 \(perRoundMB) MB \
            而不是 \(rotationGB) GB。整個片庫照樣輪得到，只是慢一些。單檔超過 \(perFileGB) GB \
            一律不收——那是片庫內容，不是桌布循環素材。
            """)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number, format: .number)
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint.opacity(0.18)))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

// MARK: - 網路來源

private struct RemoteSourceSettings: View {
    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    @State private var selection: UUID?

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
                    ForEach(settings.playlistSources) { source in
                        HStack {
                            Image(systemName: source.isEnabled ? "circle.fill" : "circle")
                                .font(.system(size: 7))
                                .foregroundStyle(source.isEnabled ? .green : .secondary)
                            Label("片單：\(source.displayTitle)", systemImage: "list.and.film")
                                .labelStyle(.titleOnly)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(source.id)
                    }
                }

                Divider()

                HStack(spacing: 0) {
                    Menu {
                        ForEach(RemoteSourceKind.allCases, id: \.self) { kind in
                            Button(kind.displayName) { add(kind) }
                        }
                        Divider()
                        Button("片單網址") { addPlaylist() }
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
                } else if let index = settings.playlistSources
                    .firstIndex(where: { $0.id == selection }) {
                    PlaylistSourceDetail(
                        source: $settings.playlistSources[index],
                        service: coordinator.playlistService,
                        settings: settings,
                        onChange: { coordinator.sourcesDidChange() }
                    )
                    .id(settings.playlistSources[index].id)
                } else {
                    ContentUnavailableView("選一個來源", systemImage: "globe",
                                           description: Text("或用左下角 + 新增。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func addPlaylist() {
        let source = PlaylistSource(urlString: "")
        settings.playlistSources.append(source)
        selection = source.id
    }

    private func add(_ kind: RemoteSourceKind) {
        let config = RemoteSourceConfig(kind: kind)
        settings.remoteSources.append(config)
        selection = config.id
        onChange()
    }

    private func remove() {
        guard let selection else { return }

        if let index = settings.playlistSources.firstIndex(where: { $0.id == selection }) {
            settings.playlistSources.remove(at: index)
            self.selection = nil
            coordinator.sourcesDidChange()
            return
        }

        guard let index = settings.remoteSources.firstIndex(where: { $0.id == selection })
        else { return }
        // key 跟著設定一起刪，不要留在 Keychain
        try? KeychainStore.set(nil, for: AppSettings.keychainAccount(for: settings.remoteSources[index]))
        settings.remoteSources.remove(at: index)
        self.selection = nil
        onChange()
    }
}

/// 片單網址的詳細頁。
///
/// 重點在「**存的是網址，不是影片**」：解析只讀清單的 metadata，
/// 真正的下載等輪替抽到那一支才發生（見 PlaylistService）。
private struct PlaylistSourceDetail: View {

    @Binding var source: PlaylistSource
    @Bindable var service: PlaylistService
    /// 畫質與登入狀態是**所有片單共用**的一份設定，不是每條片單各一份：
    /// 那是「這台機器怎麼跟 yt-dlp 打交道」，跟片單是誰無關。
    @Bindable var settings: AppSettings
    var onChange: () -> Void

    @State private var check: VideoCookieCheck?
    @State private var isChecking = false

    private static var note: AttributedString {
        let text = String(localized: """
            **存網址，不是存影片。** 加進來只會去問「這個片單裡有哪些影片」，不下載任何東西。\
            等輪替真的抽到某一支，才去抓那一支。\n所以磁碟用量跟**你真的播過幾支**成正比，\
            而不是整個片單的大小——幾百支的片單也不會一次塞爆磁碟。\n\
            抓下來的影片存進**影片快取**，跟網路來源的影片同一個地方，受同一份 2 GB \
            上限與汰舊管。
            """)
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    var body: some View {
        Form {
            Section {
                Toggle("啟用", isOn: $source.isEnabled)
                    .onChange(of: source.isEnabled) { _, _ in onChange() }
                TextField("片單網址", text: $source.urlString,
                          prompt: Text("https://…"))
                    .onSubmit(reload)
                TextField("名稱（選填）", text: $source.title,
                          prompt: source.resolvedTitle.isEmpty
                              ? Text("留白就用片單自己的標題")
                              : Text(verbatim: source.resolvedTitle))
                    .onSubmit(onChange)
            } header: {
                Text("片單網址")
            }

            Section {
                HStack {
                    if service.isRefreshing(source) {
                        ProgressView().controlSize(.small)
                        Text("解析中…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("重新解析", action: reload)
                        .disabled(source.url == nil || service.isRefreshing(source))
                }
                if let error = service.lastError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("內容")
            }

            Section {
                Picker("畫質上限", selection: $settings.videoDownloadQuality) {
                    ForEach(VideoDownloadQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text(settings.videoDownloadQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                    只抓視訊軌，不抓音訊——桌布本來就靜音播放，音訊抓下來只是佔空間。\
                    同一個解析度底下挑位元率最高的那條流：站方常常把最糊的那條排在最前面。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("改了只影響之後才抓的影片。已經在快取裡的不會重抓——要換掉就去「快取位置」清掉。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("下載畫質")
            } footer: {
                Text("所有片單共用這一份設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("借登入狀態", selection: $settings.videoCookieSource) {
                    ForEach(VideoCookieSource.allCases) { browser in
                        if browser.isInstalled() {
                            Text(browser.displayName).tag(browser)
                        } else {
                            // 沒裝的還是列出來但標明白：直接藏掉的話，
                            // 使用者只會覺得「怎麼沒有 Brave」而不知道是沒裝。
                            Text("\(browser.displayName)（這台沒裝）").tag(browser)
                        }
                    }
                }
                .onChange(of: settings.videoCookieSource) { _, _ in check = nil }

                Text("""
                    會員限定、年齡限制、私人的片單，沒有登入狀態就是解不出來；\
                    有些站也把較好的那幾條流留給登入的人。YouTube 擋自動化時\
                    （「Sign in to confirm you're not a bot」）同樣要靠它才過得去。
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.videoCookieSource != .none {
                    HStack {
                        if isChecking {
                            ProgressView().controlSize(.small)
                            Text("測試中…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            checkStatus
                        }
                        Spacer()
                        Button("測試授權", action: runCheck)
                            .disabled(isChecking)
                    }
                    checkGuidance
                }
            } header: {
                Text("借瀏覽器的登入狀態")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("""
                        Foldwall 自己不讀、不存、也不傳送任何 cookie——只是把「去哪個瀏覽器拿」\
                        這個選擇交給 yt-dlp，讀取跟使用都發生在它的行程裡，全程在這台電腦上。\
                        設定裡存下來的只有瀏覽器的名字。
                        """)
                    Text("""
                        要留意的一件事：拿已登入的帳號去大量抓片，該站有可能把那個帳號\
                        判成自動化行為。在意的話用備用帳號登入那個瀏覽器。
                        """)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text(Self.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                YtDlpNotice(version: service.toolVersion,
                            latest: service.latestToolVersion,
                            isOutdated: service.isToolOutdated)
            }
        }
        .formStyle(.grouped)
        .onAppear { if service.entryCount(for: source) == 0 { reload() } }
    }

    /// 測試結果的一行摘要。
    @ViewBuilder private var checkStatus: some View {
        switch check {
        case nil:
            Text("還沒測試過。").font(.caption).foregroundStyle(.secondary)
        case .ok(let count, let stream):
            Label(okSummary(count: count, stream: stream), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .needsFullDiskAccess:
            Label("還要一道系統授權", systemImage: "lock.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .needsKeychain:
            Label("鑰匙串那關沒過", systemImage: "key.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .browserNotFound:
            Label("在這台機器上找不到它的 cookie", systemImage: "questionmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    /// 一句一個 key，不用「開頭 ＋ 續句」拼——中文接得順的兩截，
    /// 換成英文的語序不一定還接得起來。
    private func okSummary(count: Int?, stream: String?) -> String {
        switch (count, stream) {
        case let (count?, stream?):
            String(localized: "讀到 \(count) 個 cookie，這支目前會拿到 \(stream)。")
        case let (count?, nil):
            String(localized: "讀到 \(count) 個 cookie。")
        case let (nil, stream?):
            String(localized: "可以用，這支目前會拿到 \(stream)。")
        case (nil, nil):
            String(localized: "可以用。")
        }
    }

    /// 失敗時要做什麼。**每一種失敗都給得出下一步**，否則測試只是換個地方說「不行」。
    @ViewBuilder private var checkGuidance: some View {
        switch check {
        case .needsFullDiskAccess:
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                    Safari 的 cookie 放在系統保護的位置。要授權的是 **Foldwall**，不是 yt-dlp——\
                    子行程的授權判定歸屬於把它叫起來的那個 app。
                    """)
                Text("""
                    在「完全取用磁碟」裡把 Foldwall 打開，然後回來再測一次。\
                    清單裡沒有 Foldwall 的話，用左下角的 ＋ 從「應用程式」裡加進去。
                    """)
                Button("打開「完全取用磁碟」", action: openFullDiskAccess)
                    .controlSize(.small)
                Text("不想開這道權限的話，改用 Firefox：它的 cookie 不在保護區裡，不必授權。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .needsKeychain:
            Text("""
                \(settings.videoCookieSource.displayName) 的 cookie 是加密的，金鑰在鑰匙串裡。\
                再測一次，跳出詢問時選「總是允許」。剛才如果按了「拒絕」，\
                到「鑰匙串存取」裡把那筆 Safe Storage 的權限改回來。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .browserNotFound:
            Text("""
                這台機器上沒有它的 cookie 資料庫——多半是沒裝，或裝了但還沒開過。\
                先開一次那個瀏覽器並登入要抓的站，再回來測。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ok, .failed, nil:
            EmptyView()
        }
    }

    private var status: String {
        guard source.url != nil else { return String(localized: "還沒填網址。") }
        let total = service.entryCount(for: source)
        guard total > 0 else { return String(localized: "還沒解析過。") }
        let local = service.downloadedCount(for: source)
        return String(localized: "\(total) 支，其中 \(local) 支已在本機。")
    }

    private func reload() {
        guard source.url != nil else { return }
        service.forceRefresh(source, cookies: settings.videoCookieSource)
        onChange()
    }

    private func runCheck() {
        isChecking = true
        let quality = settings.videoDownloadQuality
        let cookies = settings.videoCookieSource
        Task {
            let result = await service.verifyCookies(quality: quality, cookies: cookies)
            // 測試跑的時候使用者可能又換了一個瀏覽器——那份結果講的是舊選擇，丟掉。
            guard cookies == settings.videoCookieSource else { isChecking = false; return }
            check = result
            isChecking = false
        }
    }

    /// 系統設定的「隱私權與安全性 → 完全取用磁碟」。
    private func openFullDiskAccess() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// yt-dlp 的安裝提示。片單解析與下載都靠它，所以放在會用到它的地方；
/// 「版本」分頁另有一段講**為什麼**是外部工具（那是專案的界線，不是操作說明）。
private struct YtDlpNotice: View {

    /// 開頁時查一次就好，不必每次重繪都去磁碟上找一遍執行檔。
    @State private var isInstalled = VideoDownloadTool.locate() != nil

    /// 版號由 service 問（本機跑一次 `--version`，上游查一次 release），這裡只顯示。
    var version: String?
    var latest: String?
    var isOutdated: Bool

    var body: some View {
        if isInstalled {
            VStack(alignment: .leading, spacing: 4) {
                Label(version.map { LocalizedStringKey("已偵測到 yt-dlp \($0)") }
                          ?? LocalizedStringKey("已偵測到 yt-dlp"),
                      systemImage: isOutdated
                          ? "arrow.up.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isOutdated ? .orange : .green)
                // 只在真的有新版時才唸。查不到上游版本就什麼都不說——
                // 不確定的時候指著使用者的工具說它舊最糟。
                if isOutdated {
                    Text("有新版 \(latest ?? "")。網站一改版 extractor 就會解不出東西，先更新再排查比較省事：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("brew upgrade yt-dlp")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("需要 yt-dlp", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("片單解析與下載都靠它。安裝後回來按「重新解析」：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("brew install yt-dlp")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
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
                Text("""
                    這一頁只確認設定填對、連得上。要不要拿它合成蒙太奇或當影片來源，\
                    在「蒙太奇桌布」／「影片桌布」分頁勾選。
                    """)
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

    private var linkTitle: LocalizedStringKey {
        config.kind == .immich ? "開啟 Immich 說明文件" : "前往申請（免費）"
    }

    private var keyHint: LocalizedStringKey {
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

    private var endpointLabel: LocalizedStringKey {
        config.kind == .immich ? "伺服器網址" : "Feed 網址"
    }

    private var endpointHint: LocalizedStringKey {
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
                Text("""
                    讀不到系統的專注模式清單。macOS 沒有公開 API 可查詢目前是哪個模式，\
                    Foldwall 讀的是 ~/Library/DoNotDisturb/DB/——格式若隨系統更新改變，\
                    專注模式的規則會靜默失效，其他功能不受影響。
                    """)
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
                } else if let focus = coordinator.activeFocusModeName {
                    Text("目前沒有規則生效（專注：\(focus)）")
                } else {
                    Text("目前沒有規則生效")
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

    private var title: LocalizedStringKey {
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
                    Text("""
                        系統設定 → 螢幕保護程式 → 選「照片」類的樣式 → 選項 → 來源，\
                        把來源指到下面**照片**那一列的路徑（`~/Pictures/Foldwall`）。\
                        那是一個彙整資料夾，裡面用硬連結收攏了三個快取裡的所有圖——\
                        不佔額外空間，快取更新時會自動同步。Foldwall \
                        沒辦法把自己註冊進那個選單，所以要手動指一次。
                        """)
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

            Text("""
                兩組都在 ~/Library/Caches 底下，磁碟空間不足時 macOS 會自己刪。Foldwall \
                會重新下載，但螢幕保護程式那邊會暫時沒圖可播。目前掛在桌面上的桌布放在 \
                Application Support，不會被清掉。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .onAppear(perform: reload)
        .confirmationDialog(
            pendingClear.map { String(localized: "清除「\($0.name)」？") } ?? "",
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
            String(localized: "輪替中的影片會被移除，影片螢幕暫由蒙太奇接管，下次螢幕睡著時再預先拷一批。")
        default:
            String(localized: """
                清完**不會立刻重新下載**，等下一個排程輪次自然補回來。\
                目前掛在桌面上的桌布不受影響。
                """)
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
        HStack(alignment: .top, spacing: 0) {
            sourceColumn
                .frame(width: 232)
            Divider()
            controlColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 左欄：來源

    /// 來源可以有幾十個（照片相簿一台機器就十幾個），視窗高度是固定的 520——
    /// 沒有 ScrollView 的話後面幾個會被切掉而且捲不到，看起來就像卡住了。
    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("要用哪些來源")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            ScrollView {
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
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: - 右欄：這一輪怎麼抽

    private var controlColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.secondary)
                    Text(poolSummary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("下一張") { coordinator.next() }
                }
                .padding(4)
            }

            // 不用 Form(.grouped)：那是 List，會把右欄剩下的高度全吃光，
            // 底下的張數表就被推到視窗最下面、中間空一大塊。GroupBox 才貼著內容長。
            // 標籤靠左、控制項推到尾端，右緣就跟上面那格的「下一張」對齊。
            GroupBox {
                VStack(spacing: 10) {
                    controlRow("切換間隔") {
                        Picker("", selection: Binding(
                            get: { settings.intervalMinutes },
                            set: { coordinator.setInterval($0) }
                        )) {
                            ForEach(Scheduler.intervalOptions, id: \.self) { minutes in
                                Text(Scheduler.intervalLabel(minutes)).tag(minutes)
                            }
                        }
                    }

                    controlRow("後製") {
                        Picker("", selection: Binding(
                            get: { settings.effect },
                            set: { coordinator.setEffect($0) }
                        )) {
                            ForEach(PostProcess.allCases, id: \.self) { effect in
                                Text(effect.displayName).tag(effect)
                            }
                        }
                    }

                    controlRow("顯示來源與作者") {
                        Toggle("", isOn: Binding(
                            get: { settings.showCredits },
                            set: { coordinator.setShowCredits($0) }
                        ))
                        .toggleStyle(.switch)
                    }

                    controlRow("張數上限") {
                        Picker("", selection: Binding(
                            get: { settings.montagePieceCount },
                            set: { coordinator.setPieceCount($0) }
                        )) {
                            Text("自動").tag(Int?.none)
                            Divider()
                            ForEach(Array(MontageComposer.pieceCountRange), id: \.self) { count in
                                Text(count == 1
                                     ? LocalizedStringKey("固定 1 張")
                                     : LocalizedStringKey("最多 \(count) 張"))
                                    .tag(Int?.some(count))
                            }
                        }
                    }
                }
                .padding(4)
            }

            GroupBox("每台螢幕張數上限") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(coordinator.displays, id: \.uuid) { display in
                        let longSide = max(display.canvas.width, display.canvas.height)
                        let ceiling = StillPipeline.pieceCountCeiling(
                            longSide: longSide, tier: .full,
                            override: settings.montagePieceCount
                        )
                        HStack(spacing: 6) {
                            Text(ScreenBridge.localizedName(forUUID: display.uuid)
                                 ?? String(localized: "未知螢幕"))
                                .lineLimit(1)
                            Text("\(Int(display.canvas.width))×\(Int(display.canvas.height))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer(minLength: 8)
                            Text(ceiling == 1
                                 ? LocalizedStringKey("1 張")
                                 : LocalizedStringKey("1–\(ceiling) 張"))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    Text(creditNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    Text(pieceCountNote)
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

    /// 標籤靠左、控制項靠右：右緣與上面那格的「下一張」在同一條線上。
    private func controlRow<Control: View>(
        _ label: LocalizedStringKey, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 8)
            control()
                .labelsHidden()
                .fixedSize()
        }
    }

    private var creditNote: LocalizedStringKey {
        settings.showCredits
            ? "作者印在每張照片的相紙下緣；相紙太小放不下的，收到右下角一起列。"
            : """
                已關閉。Unsplash 與 Pexels 的授權要求標註作者——\
                關掉之後這些來源的圖只適合自己看。
                """
    }

    /// 三種寫法各自是完整一句，不用「共通句 ＋ 前綴」拼——中文接得起來的順序，
    /// 換成英文不一定接得起來，拼句子等於把語序寫死在程式碼裡。
    private var pieceCountNote: LocalizedStringKey {
        switch settings.montagePieceCount {
        case nil:
            """
                自動：上限依螢幕長邊決定。每輪實際幾張是在 1 到上限之間隨機決定的——\
                有時一張大圖、有時鋪滿十幾張。每台螢幕各自抽圖、各自合成，\
                同一時間兩台不會是同一張。降載時上限封頂 6 張。
                """
        case 1:
            "上限 1 張＝每輪固定單張大圖，不再隨機。每台螢幕各自抽圖。降載時一樣是 1 張。"
        default:
            """
                指定的上限對所有螢幕一體適用。每輪實際幾張是在 1 到上限之間隨機決定的——\
                有時一張大圖、有時鋪滿十幾張。每台螢幕各自抽圖、各自合成，\
                同一時間兩台不會是同一張。降載時上限封頂 6 張。
                """
        }
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
        if status.isIndexing && status.poolCount == 0 {
            return String(localized: "正在掃描資料夾…")
        }
        var parts = [String(localized: "池 \(status.poolCount) 張")]
        if status.remoteCount > 0 { parts.append(String(localized: "網路 \(status.remoteCount)")) }
        if status.photosCount > 0 { parts.append(String(localized: "相簿 \(status.photosCount)")) }
        if status.isIndexing { parts.append(String(localized: "掃描中")) }
        return parts.joined(separator: String(localized: "・"))
    }

}

// MARK: - 備份

/// 設定備份與 iCloud 同步。
///
/// 這一頁的重點是講清楚**兩層**：來源三台通用，桌布設定每台一份。
/// 使用者第一次看到「同步」兩個字時的預期是「全部一樣」，而這裡刻意不是——
/// 沒講清楚的話，他會以為在筆電關掉的來源沒同步成功。
private struct BackupSettings: View {

    @Bindable var coordinator: WallpaperCoordinator
    @Bindable var settings: AppSettings

    /// 要匯入哪一台的桌布設定。挑了才顯示確認按鈕——這個動作會蓋掉這台的設定。
    @State private var pendingImport: SettingsBackup.DeviceFile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !coordinator.backup.isAvailable {
                    GroupBox {
                        Label("這台沒有啟用 iCloud Drive，備份功能停用。",
                              systemImage: "exclamationmark.triangle")
                            .padding(4)
                    }
                }

                GroupBox("兩層") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("來源 → 三台通用",
                            String(localized: """
                                資料夾、網路來源、片單的**定義**寫在共用的 `sources.json`。\
                                在一台加的來源，別台也會出現；在一台刪掉的，別台也會清掉。
                                """))
                        row("這台用哪些 → 依設備",
                            String(localized: """
                                每個來源的**開關**、資料夾用途、選中的相簿都留在這台。\
                                在筆電關掉 Pexels 不會讓桌機也跟著關；\
                                目錄裡新出現的來源在每台都是**預設開著**。
                                """))
                        row("桌布怎麼播 → 依設備",
                            String(localized: """
                                切換間隔、後製、同時抽取張數、影片引擎／圖層／播放／縮放／畫質、\
                                狀態規則、登入時啟動——全部各台各自一份，寫在 \
                                `devices/` 底下以機器命名的檔案裡，**只有同一台會自動讀回來**。
                                """))
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button {
                                coordinator.backupSettingsToICloud()
                            } label: {
                                Label("備份到 iCloud", systemImage: "icloud.and.arrow.up")
                            }
                            Button {
                                coordinator.restoreSettingsFromICloud()
                            } label: {
                                Label("從 iCloud 更新來源", systemImage: "icloud.and.arrow.down")
                            }
                            Spacer()
                            Button("在 Finder 顯示") { coordinator.backup.revealInFinder() }
                        }

                        Text("「備份到 iCloud」會寫兩層；「更新來源」只拉共用的那層，不會動這台的桌布設定。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let summary = coordinator.backup.catalogSummary {
                            Label("iCloud 上的來源目錄：\(summary)", systemImage: "checkmark.icloud")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("iCloud 上還沒有來源目錄。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        switch coordinator.backup.status {
                        case .idle:
                            EmptyView()
                        case .ok(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Text(coordinator.backup.displayPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .disabled(!coordinator.backup.isAvailable)

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("自動與 iCloud 同步", isOn: $settings.iCloudSyncEnabled)
                            .onChange(of: settings.iCloudSyncEnabled) { _, _ in
                                coordinator.iCloudSyncDidChange()
                            }
                        Text(Self.autoSyncNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .disabled(!coordinator.backup.isAvailable)

                deviceImport

                GroupBox("不會備份的") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("API key",
                            String(localized: """
                                備份檔是明文 JSON，放在 iCloud Drive 裡會被 Spotlight 索引。\
                                換機器時到「來源」分頁重輸一次。
                                """))
                        row("資料夾書籤",
                            String(localized: """
                                存的是**路徑**不是書籤——書籤綁著建立它的那台機器。\
                                另一台沒掛那顆磁碟的路徑會被跳過，但**不會**從共用目錄裡消失。
                                """))
                        row("輪到第幾支影片了",
                            String(localized: """
                                那是執行狀態不是設定，跨機同步只會讓兩台互相打斷輪替。
                                """))
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .onAppear { coordinator.backup.refreshSummaries() }
    }

    /// 別台（或這台的舊備份）的桌布設定。平常用不到——它是換機器時的那條路。
    @ViewBuilder
    private var deviceImport: some View {
        GroupBox("各台的桌布設定") {
            VStack(alignment: .leading, spacing: 8) {
                if coordinator.backup.deviceFiles.isEmpty {
                    Text("iCloud 上還沒有任何一台的桌布設定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(coordinator.backup.deviceFiles) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(file.deviceName).font(.caption.bold())
                                    if file.isSelf {
                                        Text("（這台）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(file.savedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if pendingImport == file {
                                Button("確定覆蓋這台") {
                                    coordinator.importDeviceSettings(from: file)
                                    pendingImport = nil
                                }
                                .buttonStyle(.borderedProminent)
                                Button("取消") { pendingImport = nil }
                            } else {
                                Button("匯入") { pendingImport = file }
                            }
                        }
                    }
                }
                Text(Self.deviceImportNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .disabled(!coordinator.backup.isAvailable)
    }

    /// `Text(.init(字串))` 只會把 `**` 吃掉不上粗體——那條路是查本地化鍵，
    /// 非字面量的 key 查不到、退回原字串時屬性就掉了。要先解析成 AttributedString。
    private static func markdown(_ source: String) -> AttributedString {
        (try? AttributedString(markdown: source)) ?? AttributedString(source)
    }

    private static var autoSyncNote: AttributedString {
        markdown(String(localized: """
            開著的話，這台的來源一改就寫上去，別台也會自動跟上；同一輪裡兩邊都改過\
            就**以 iCloud 上那份為準**——沒有合併，後寫的贏。\
            桌布設定只會**往上備份**，不會自動套到別台。\
            只想要單向搬家的話，用上面兩顆按鈕就好。
            """))
    }

    private static var deviceImportNote: AttributedString {
        markdown(String(localized: """
            換掉一台 Mac 時用這裡把舊機的桌布設定接過來。**會覆蓋這台目前的設定。**\
            從**別台**匯入時會跳過「此螢幕改用影片」與「借瀏覽器 cookie」——\
            前者存的是顯示器 UUID、每台都不同，後者的授權在新機器上本來就要重來。
            """))
    }

    private func row(_ title: LocalizedStringKey, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.bold())
            Text(Self.markdown(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 語言

/// 內建繁中／簡中／英文；其他語言讓使用者用本機 AI CLI 翻，翻好重啟生效。
/// 「用哪個語言」與「翻譯哪個語言」是兩件事：前者是一個 Picker（內建＋已翻好的），
/// 選回內建不會刪檔；後者在下面另一組控制項。
private struct LanguageSettings: View {

    @Bindable var translator: UITranslator

    /// Picker 的 tag：nil（內建）在 SwiftUI 裡不好當 tag，用空字串代表。
    private static let builtinTag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("介面語言") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("介面語言", selection: Binding(
                            get: { translator.selectedLanguage ?? Self.builtinTag },
                            set: { translator.selectedLanguage = $0 == Self.builtinTag ? nil : $0 }
                        )) {
                            Text("內建（繁體中文／简体中文／English，跟隨系統）").tag(Self.builtinTag)
                            ForEach(translator.installedLanguages, id: \.self) { code in
                                Text(UITranslator.displayName(for: code)).tag(code)
                            }
                        }
                        .disabled(translator.isRunning)

                        if translator.needsRelaunch {
                            HStack(spacing: 8) {
                                Button("重新啟動以套用") { translator.relaunch() }
                                Text("選好的語言要重新啟動 Foldwall 才會切換。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(translator.installedLanguages, id: \.self) { code in
                            if let manifest = translator.manifest(for: code) {
                                installedRow(code: code, manifest: manifest)
                            }
                        }

                        Text("""
                            Foldwall 內建繁體中文、簡體中文與英文。其他語言可以交給**本機的 AI CLI**\
                            （Claude Code、Codex 等，用你自己登入的帳號）翻譯全部介面文字；\
                            翻好的檔只存在這台 Mac，隨時可以切回內建語言。\
                            這是機器翻譯，翻不好的字串會退回英文。
                            """)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }

                GroupBox("用本機的 AI CLI 翻譯") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("翻譯成", selection: $translator.targetLanguage) {
                            ForEach(translator.candidateLanguages, id: \.self) { code in
                                Text(UITranslator.displayName(for: code)).tag(code)
                            }
                        }
                        .disabled(translator.isRunning)

                        engineSection

                        phaseView

                        HStack(spacing: 8) {
                            Button(translator.installedLanguages.contains(translator.targetLanguage) ? "全部重翻" : "開始翻譯") {
                                translator.translate(onlyMissing: false)
                            }
                            .disabled(translator.isRunning || translator.activeEngine == nil)
                            Text("約 \(translator.builtinStringCount) 條字串，40 條一批送出，通常幾分鐘內完成。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .task { translator.registry.scanIfNeeded() }
    }

    /// 一個已翻好語言的狀態列：條數、日期、引擎，加上補翻與移除。
    @ViewBuilder
    private func installedRow(code: String, manifest: UITranslationStore.Manifest) -> some View {
        let missing = translator.missingCount(for: code)
        HStack(spacing: 8) {
            Text(UITranslator.displayName(for: code))
            Text("\(manifest.translated) 條・\(manifest.engineID)・\(manifest.date, format: .dateTime.year().month().day())")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if missing > 0 {
                Button("補翻 \(missing) 條新字串") {
                    translator.targetLanguage = code
                    translator.translate(onlyMissing: true)
                }
                .controlSize(.small)
                .disabled(translator.isRunning || translator.activeEngine == nil)
            }
            Button("移除", role: .destructive) { translator.remove(language: code) }
                .controlSize(.small)
                .disabled(translator.isRunning)
        }
    }

    /// 引擎：目錄裡五家全列，沒裝的標出來；選中的那家給路徑／版本與模型欄位。
    @ViewBuilder
    private var engineSection: some View {
        let registry = translator.registry
        Picker("引擎", selection: $translator.engineID) {
            ForEach(KnownCLIEngine.catalog) { engine in
                if registry.detected(engine.id) != nil {
                    Text(engine.displayName).tag(engine.id)
                } else {
                    Text("\(engine.displayName)（未安裝）").tag(engine.id)
                }
            }
        }
        .disabled(translator.isRunning)

        if let engine = KnownCLIEngine.named(translator.engineID) {
            if let detected = registry.detected(engine.id) {
                // 家目錄縮成 ~：路徑短一截，截圖時也不會露出使用者名稱
                Text((detected.url.path as NSString).abbreviatingWithTildeInPath
                    + (detected.version.map { "（\($0)）" } ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if engine.supportsModelSelection {
                    HStack(spacing: 6) {
                        Text("模型")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: Binding(
                            get: { translator.model(for: engine.id) },
                            set: { translator.setModel($0, for: engine.id) }
                        ), prompt: Text("預設"))
                        .labelsHidden()
                        .font(.caption)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .help(engine.modelHint)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                Text("沒偵測到 `\(engine.executableName)`。裝好之後按「重新掃描」，或填入執行檔的完整路徑：")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: Binding(
                    get: { translator.customPath(for: engine.id) },
                    set: { translator.setCustomPath($0, for: engine.id) }
                ), prompt: Text(verbatim: "/opt/homebrew/bin/\(engine.executableName)"))
                .labelsHidden()
                .font(.caption.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { registry.rescan() }
            }
            if let active = translator.activeEngine, active.id != engine.id {
                // 選的那家沒裝時會回落到裝了的那家，要講清楚實際會用誰
                Text("實際會使用 \(active.engine.displayName)。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }

        HStack(spacing: 8) {
            Button("重新掃描") { registry.rescan() }
                .controlSize(.small)
                .disabled(translator.isRunning)
            Text("掃描順序：自訂路徑 → PATH → 常見安裝位置。Foldwall 不經手任何 API key，計費在你自己的訂閱上。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch translator.phase {
        case let .running(done, total):
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("翻譯中 \(done)／\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("取消") { translator.cancel() }
                    .controlSize(.small)
            }
        case let .finished(translated, skipped):
            Label(
                skipped == 0
                    ? String(localized: "已翻譯 \(translated) 條。")
                    : String(localized: "已翻譯 \(translated) 條，\(skipped) 條翻不好、退回英文。"),
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case let .failed(message, loginCommand):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if let loginCommand {
                    HStack(spacing: 6) {
                        Text("到終端機執行：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(loginCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("複製") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(loginCommand, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
            }
        case .idle:
            EmptyView()
        }
    }
}

#Preview("語言") {
    let defaults = UserDefaults(suiteName: "app.foldwall.preview.language")!
    let settings = AppSettings(defaults: defaults)
    let registry = CLIEngineRegistry(settings: settings)
    registry.injectDetected([
        .init(engine: KnownCLIEngine.named("claude")!,
              url: URL(fileURLWithPath: "/Users/me/.local/bin/claude"), version: "2.1.0"),
    ])
    let store = UITranslationStore(directory: FileManager.default.temporaryDirectory
        .appending(path: "foldwall-preview-uitranslations"))
    try? store.write(
        language: "ja", strings: ["下一張": "次へ"], plurals: [:], pluralValueTypes: [:],
        manifest: .init(language: "ja", engineID: "claude", model: nil, date: .now,
                        sourceBuild: "46", translated: 367, skipped: []))
    let translator = UITranslator(store: store, settings: settings, registry: registry)
    translator.targetLanguage = "ja"
    return LanguageSettings(translator: translator)
        .frame(width: 640, height: 520)
}

// MARK: - 版本

private struct AboutSettings: View {

    /// 為什麼靠外部工具，而不是自己解析。這是專案的**界線**，屬於「關於」；
    /// 「這台裝了沒、怎麼裝」那種操作提示放在會用到它的地方（片單網址）。
    private static var ytdlpRationale: AttributedString {
        let text = String(localized: """
            片單解析與影片下載都是呼叫**你自己安裝的 yt-dlp**，Foldwall \
            不實作任何串流解析或簽章繞過——那是規避技術保護措施。這裡只負責找到工具、組出參數、\
            把結果收進影片來源；要對哪個站用由你決定。\n順帶的好處是 yt-dlp 支援上千個站，\
            不必為每一個寫解析器；代價是**沒裝就用不了**這兩個功能，其他來源不受影響。
            """)
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "\(short)（build \(build)）")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Foldwall").font(.title2.bold())
                    Text(version).foregroundStyle(.secondary).monospacedDigit()
                    Text("macOS 26+・Apple Silicon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Text("""
                從資料夾、照片相簿與免 OAuth 的網路來源隨機合成蒙太奇桌布，\
                並支援影片桌布（桌面＋鎖屏）。
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("外部工具") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.ytdlpRationale)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let tool = VideoDownloadTool.locate() {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(tool.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                            Text("未安裝——`brew install yt-dlp`")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    // ffmpeg 也要講：YouTube 現在幾乎只給分離的視訊／音訊軌，
                    // 沒有它 yt-dlp 一支也合不出來（Requested format is not available）。
                    HStack(spacing: 6) {
                        if let ffmpeg = VideoDownloadTool.locateFFmpeg() {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text(ffmpeg.path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("""
                                沒有 ffmpeg——`brew install ffmpeg`。YouTube \
                                這類站只提供分離的視訊／音訊軌，沒有它就合併不了，\
                                片單一支也抓不下來。
                                """)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(4)
            }

            GroupBox("授權") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Foldwall 以 MIT 授權釋出。")
                        .font(.caption)
                    Text("""
                        影片桌布 extension fork 自 **Phosphene**（MIT），\
                        授權原文隨原始碼一起保留。
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("""
                        照片由 Unsplash／Pexels／Pixabay／Wallhaven 等來源提供，\
                        各自的使用規範以該站條款為準。
                        """)
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

