import AppKit

enum LaunchArgs {
    /// 启动时待载入的文件（--open 参数），用于 Dock 拖入与自测
    static var pending: [URL] = []
}

/// 外部入口希望进入的模式：右键服务/URL scheme 会指定，普通打开走 auto
enum LaunchMode {
    case auto, extract, compress, encrypt
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    /// 冷启动时服务先到、窗口未建，先记下来，建完窗口再补
    private var pendingMode: LaunchMode = .auto

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 关键：Info.plist 里的 NSServices 只是"声明"，AppKit 不会自动打开 Services 端口。
        // 不注册这一步，系统调用服务时会报 "never opened its Services port"，
        // 右键菜单项也拿不到提供者，最终表现为"服务菜单里根本没有这一项"。
        NSRegisterServicesProvider(self, "Squash")

        let vc = MainViewController()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Squash"
        window.contentViewController = vc
        // 标题交给界面里自绘的头部，交通灯直接浮在内容上
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !LaunchArgs.pending.isEmpty {
            vc.setItems(LaunchArgs.pending)
            applyMode(pendingMode, to: vc)
            if ProcessInfo.processInfo.environment["SQUASH_ENCRYPT"] == "1" {
                vc.activateEncryptMode()
            }
            pendingMode = .auto
        }

        // --snapshot：把窗口渲染成 PNG 后退出，用于无干扰地检查界面
        if let out = ProcessInfo.processInfo.environment["SQUASH_SNAPSHOT"], !out.isEmpty {
            // SQUASH_DARK=1 用来核对深色外观
            if ProcessInfo.processInfo.environment["SQUASH_DARK"] == "1" {
                window.appearance = NSAppearance(named: .darkAqua)
            }
            let autostart = ProcessInfo.processInfo.environment["SQUASH_AUTOSTART"] == "1"
            // SQUASH_DELAY 可覆盖等待时间，用来截「进行中」这种瞬时界面
            let defaultDelay: Double = autostart ? 2.4 : 1.2
            let delay = ProcessInfo.processInfo.environment["SQUASH_DELAY"]
                .flatMap(Double.init) ?? defaultDelay
            if autostart { vc.startForSnapshot() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let cv = self.window.contentView,
                      let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else {
                    exit(1)
                }
                print("snapshot diag: key=\(self.window.isKeyWindow) active=\(NSApp.isActive)")
                cv.cacheDisplay(in: cv.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("snapshot -> \(out)")
                }
                exit(0)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        deliver([URL(fileURLWithPath: filename)])
        return true
    }

    /// Dock 图标拖入多个文件、或 open -a 一次传多个时走这里。
    /// 注意：这个回调可能发生在 finishLaunching 阶段，那时 window 还没建好，
    /// 直接取 window.contentViewController 会因隐式解包 nil 而崩溃。
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        deliver(filenames.map { URL(fileURLWithPath: $0) })
        NSApp.reply(toOpenOrPrint: .success)
    }

    private func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let vc = window?.contentViewController as? MainViewController {
            vc.setItems(urls)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            LaunchArgs.pending = urls
        }
    }

    // MARK: URL scheme（squash://extract?path=… / squash://encrypt?path=…）

    /// Finder 的「快速操作」是独立工作流进程，只能通过 open 命令把文件转进来。
    /// `open -a` 在 App 已运行时无法追加文件，所以走自定义 scheme：
    /// 无论 App 是否在跑，系统都会把 URL 投给同一个实例。
    private var urlBatch: [URL] = []
    private var urlBatchEncrypt = false
    private var urlBatchScheduled = false

    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            guard u.scheme?.lowercased() == "squash" else {
                files.append(u)                     // 纯文件 URL 也接
                continue
            }
            if u.host?.lowercased() == "encrypt" { urlBatchEncrypt = true }
            if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
               let raw = comps.queryItems?.first(where: { $0.name == "path" })?.value,
               !raw.isEmpty {
                files.append(URL(fileURLWithPath: raw))
            }
        }
        guard !files.isEmpty else { return }
        urlBatch.append(contentsOf: files)
        guard !urlBatchScheduled else { return }
        urlBatchScheduled = true
        // 多选时系统会分多次回调，攒一小会儿一次性入队，避免后一个把前一个覆盖掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.flushURLBatch()
        }
    }

    private func flushURLBatch() {
        let files = urlBatch
        let encrypt = urlBatchEncrypt
        urlBatch.removeAll()
        urlBatchEncrypt = false
        urlBatchScheduled = false
        guard !files.isEmpty else { return }
        apply(files, encrypt ? .encrypt : .auto)
    }

    /// 把文件交给界面并按需要切换模式；窗口还没建好就先缓存模式
    private func apply(_ urls: [URL], _ mode: LaunchMode) {
        guard !urls.isEmpty else { return }
        if let vc = window?.contentViewController as? MainViewController {
            vc.setItems(urls)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            applyMode(mode, to: vc)
        } else {
            LaunchArgs.pending = urls
            pendingMode = mode
        }
    }

    private func applyMode(_ mode: LaunchMode, to vc: MainViewController) {
        switch mode {
        case .auto:     break
        case .extract:  vc.activateExtractMode()
        case .compress: vc.activateCompressMode()
        case .encrypt:  vc.activateEncryptMode()
        }
    }

    // MARK: Finder 右键服务

    /// 服务面板送进来的是文件 URL 列表
    private func files(from pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func squashExtract(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        apply(files(from: pboard), .extract)
    }

    @objc func squashCompress(_ pboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        apply(files(from: pboard), .compress)
    }

    @objc func squashEncrypt(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        apply(files(from: pboard), .encrypt)
    }
}

@main
struct SquashMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        // 注意：命令行里的文件路径会被 AppKit 当成“逐个打开”逐次回调，
        // 想一次塞多个文件必须走环境变量（换行分隔）。
        if let env = ProcessInfo.processInfo.environment["SQUASH_OPEN"], !env.isEmpty {
            LaunchArgs.pending = env.split(separator: "\n").map {
                URL(fileURLWithPath: String($0))
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
