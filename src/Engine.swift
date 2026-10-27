import Foundation

/// 7-Zip 官方命令行引擎的封装。
/// 二进制随 App 打包在 Resources 目录，不写入系统。
enum Engine {
    static var binary: URL {
        Bundle.main.resourceURL!.appendingPathComponent("7zz")
    }

    /// 执行一次 7zz。
    /// - Parameters:
    ///   - workingDirectory: 指定工作目录。重打包时必须用它，
    ///     否则 7zz 会把源路径前缀一起写进包内，凭空多套一层目录。
    /// - 注意：stdin 已接 /dev/null。7zz 在未给密码的加密包上会等待终端输入，
    ///   不关掉 stdin 会永久挂起（实测踩过）。
    @discardableResult
    static func run(_ args: [String],
                    workingDirectory: URL? = nil,
                    onProgress: ((Int) -> Void)? = nil,
                    onFinish: @escaping (Bool, String) -> Void) -> Process {
        let p = Process()
        p.executableURL = binary
        p.arguments = args + ["-y", "-bd"]
        if let workingDirectory { p.currentDirectoryURL = workingDirectory }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        var collected = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            guard let s = String(data: data, encoding: .utf8) else { return }
            lock.lock(); collected += s; lock.unlock()
            guard let onProgress else { return }
            for seg in s.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                if let r = seg.range(of: #"\d{1,3}%"#, options: .regularExpression) {
                    let n = Int(seg[r].dropLast().trimmingCharacters(in: .whitespaces)) ?? 0
                    DispatchQueue.main.async { onProgress(min(max(n, 0), 100)) }
                }
            }
        }

        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            // 收尾再读一次，避免最后一段输出丢失
            let tail = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: tail, encoding: .utf8) {
                lock.lock(); collected += s; lock.unlock()
            }
            lock.lock(); let text = collected; lock.unlock()
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async { onFinish(ok, text) }
        }
        try? p.run()
        return p
    }

    /// 同步执行一遍列表，用于开跑前的探测（是否加密、内部是否还有压缩包）
    static func listEntries(_ archive: URL, password: String?) -> [EngineEntry] {
        let p = Process()
        p.executableURL = binary
        var a = ["l", "-slt", "-ba"]
        if let password, !password.isEmpty { a.append("-p\(password)") }
        a.append(archive.path)
        p.arguments = a + ["-y", "-bd"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var entries: [EngineEntry] = []
        var path = ""
        var encrypted = false
        var isDir = false
        var size: Int64 = 0
        func flush() {
            guard !path.isEmpty else { return }
            entries.append(EngineEntry(path: path, isDirectory: isDir,
                                       encrypted: encrypted, size: size))
            path = ""; encrypted = false; isDir = false; size = 0
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("Path = ") {
                flush()
                path = String(line.dropFirst(7))
            } else if line.hasPrefix("Size = ") {
                size = Int64(line.dropFirst(7)) ?? 0
            } else if line.hasPrefix("Encrypted = ") {
                encrypted = line.dropFirst(12).trimmingCharacters(in: .whitespaces) == "+"
            } else if line.hasPrefix("Folder = ") {
                isDir = line.dropFirst(9).trimmingCharacters(in: .whitespaces) == "+"
            } else if line.hasPrefix("Attributes = ") {
                if line.contains(" D") { isDir = true }
            }
        }
        flush()
        return entries
    }

    static func humanize(_ log: String) -> String {
        if log.contains("Wrong password") { return "密码错误，或压缩包未加密" }
        if log.contains("Cannot open the file as archive") { return "无法识别的压缩包格式" }
        if log.contains("No such file or directory") { return "文件不存在或已被移动" }
        if log.contains("is not supported") { return "该格式不受支持" }
        if log.contains("E_NOTIMPL") { return "该压缩包使用了未实现的算法" }
        if log.contains("Broken pipe") { return "已取消" }
        if log.contains("Data Error") { return "数据损坏，文件可能不完整" }
        if log.contains("Headers Error") { return "压缩包头部损坏" }
        // 取 7z 报的第一行 ERROR
        if let line = log.split(separator: "\n").first(where: { $0.contains("ERROR") }) {
            return String(line).trimmingCharacters(in: .whitespaces)
        }
        return "操作失败，退出码非 0"
    }
}

struct EngineEntry {
    let path: String
    let isDirectory: Bool
    let encrypted: Bool
    let size: Int64

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}
