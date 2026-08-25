//  Log.swift
//  5 分鐘一次的背景排程壞掉很難查，統一走 os.Logger 方便 `log stream --predicate`。

import OSLog

enum Log {
    static let app = Logger(subsystem: "app.foldwall", category: "app")
    static let pipeline = Logger(subsystem: "app.foldwall", category: "pipeline")
    static let sources = Logger(subsystem: "app.foldwall", category: "sources")
}
