//  App.swift
//  選單列殼。完整選單在 Task 7。

import SwiftUI
import FoldwallCore

@main
struct FoldwallApp: App {
    var body: some Scene {
        // 選單列 app：沒有 WindowGroup，啟動不跳空視窗
        MenuBarExtra("Foldwall", systemImage: "photo.on.rectangle.angled") {
            Text("Foldwall \(FoldwallCore.version)")
            Divider()
            Button("結束 Foldwall") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
