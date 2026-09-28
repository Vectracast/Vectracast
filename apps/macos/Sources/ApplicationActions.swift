import AppKit

/// Resolves an already broker-issued app path; plugins never supply a file or script to execute.
enum ApplicationActions {
    static func perform(_ type: String, url: URL, completion: @escaping (String?) -> Void) {
        guard url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path) else { completion("应用已移动或删除，请刷新搜索"); return }
        switch type {
        case "application.open":
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in DispatchQueue.main.async { completion(error == nil ? nil : "打开应用失败") } }
        case "application.reveal": NSWorkspace.shared.activateFileViewerSelecting([url]); completion(nil)
        case "application.contents":
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            guard FileManager.default.fileExists(atPath: contents.path), NSWorkspace.shared.open(contents) else { completion("未找到应用包内容"); return }
            completion(nil)
        case "application.info":
            // Execute a fixed bundled operation in a separate process: Finder can wait for
            // Automation consent without blocking AppKit. The path is an argv value, not code.
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", """
            on run argv
                with timeout of 10 seconds
                    set targetFile to POSIX file (item 1 of argv) as alias
                    tell application "Finder"
                        open information window of targetFile
                        activate
                    end tell
                end timeout
            end run
            """, "--", url.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            process.terminationHandler = { task in
                let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 { completion(nil) }
                    else if message.contains("-1743") { completion("显示简介需要允许 Vectracast 控制 Finder，可在系统设置 → 隐私与安全性 → 自动化中开启") }
                    else { completion("Finder 简介请求超时或失败，请重试") }
                }
            }
            do {
                try process.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if process.isRunning { process.terminate() } }
            } catch { completion("无法启动 Finder 简介请求") }
        default: completion("不支持此应用操作")
        }
    }
}
