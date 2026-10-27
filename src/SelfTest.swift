import Foundation

/// 无头自测：直接驱动 BatchRunner 跑真实代码路径，验证三项新功能。
/// 用法：Squash.app/Contents/MacOS/Squash --selftest
enum SelfTest {

    private static let fm = FileManager.default
    private static let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("squash-selftest", isDirectory: true)

    static func run() -> Int32 {
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        print("=== Squash 自测 ===")
        print("工作目录: \(root.path)\n")

        var failures = 0
        failures += batchExtract()
        failures += nestedExtract()
        failures += reencrypt()
        failures += gbkNames()

        print(failures == 0 ? "\n✅ ALL PASS" : "\n❌ \(failures) 项失败")
        return failures == 0 ? 0 : 1
    }

    // MARK: 场景 4：GBK 文件名（Windows 打包的 zip）

    private static func gbkNames() -> Int {
        print("[4] GBK 文件名解压不乱码")
        let dir = root.appendingPathComponent("gbk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let zip = dir.appendingPathComponent("winmade.zip")
        makeGBKZip(at: zip, entries: [
            ("中文资料.txt", "正文一"),
            ("测试文件夹/内容.txt", "正文二"),
        ])
        guard fm.fileExists(atPath: zip.path) else {
            print("    ✗ 造包失败"); print(""); return 1
        }

        let jobs = [Job(sources: [zip], kind: .extract)]
        let result = drive(jobs, settings: BatchSettings())

        var ok = result.failed == 0
        guard let out = jobs.first?.output else {
            print("    ✗ 没有解出目录"); print(""); return 1
        }
        let names = ((try? fm.contentsOfDirectory(atPath: out.path)) ?? []).sorted()
        if !names.contains("中文资料.txt") || !names.contains("测试文件夹") {
            ok = false
            print("    ✗ 文件名仍不正常: \(names)")
        }
        if findFile(named: "内容.txt", in: out) == nil {
            ok = false; print("    ✗ 子目录里的文件没解出来")
        }
        // 内容要完好
        let body = (try? String(contentsOf: out.appendingPathComponent("中文资料.txt"),
                                encoding: .utf8)) ?? ""
        if body != "正文一" { ok = false; print("    ✗ 内容损坏: \(body)") }

        print(ok ? "    ✓ 名字与内容都正确（\(jobs.first?.message ?? "")）" : "    ✗ 失败")
        print("")
        return ok ? 0 : 1
    }

    // MARK: 场景 1：批量解压三个压缩包

    private static func batchExtract() -> Int {
        print("[1] 批量解压 3 个压缩包")
        let dir = root.appendingPathComponent("batch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var archives: [URL] = []
        for i in 1...3 {
            let z = dir.appendingPathComponent("pack\(i).zip")
            makeZip(at: z, entries: ["file\(i).txt": "内容\(i)"])
            archives.append(z)
        }
        let sevenZ = dir.appendingPathComponent("pack4.7z")
        make7z(at: sevenZ)
        archives.append(sevenZ)

        let jobs = archives.map { Job(sources: [$0], kind: .extract) }
        let result = drive(jobs, settings: BatchSettings())

        var ok = true
        if result.failed > 0 { ok = false; print("    ✗ 有 \(result.failed) 个任务失败") }
        for job in jobs {
            guard let out = job.output else { ok = false; print("    ✗ \(job.displayName) 无输出"); continue }
            let inner = (try? fm.contentsOfDirectory(atPath: out.path)) ?? []
            if inner.isEmpty { ok = false; print("    ✗ \(out.lastPathComponent) 解出来是空的") }
        }
        print(ok ? "    ✓ 4 个任务全部完成" : "    ✗ 失败")
        print("")
        return ok ? 0 : 1
    }

    // MARK: 场景 2：嵌套解压

    private static func nestedExtract() -> Int {
        print("[2] 嵌套解压（zip 里套 zip）")
        let dir = root.appendingPathComponent("nested", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 先造内层
        let innerDir = dir.appendingPathComponent("inner_src", isDirectory: true)
        try? fm.createDirectory(at: innerDir, withIntermediateDirectories: true)
        try? "深层机密".write(to: innerDir.appendingPathComponent("deep.txt"),
                             atomically: true, encoding: .utf8)
        let innerZip = dir.appendingPathComponent("inner.zip")
        _ = sh(["a", "-tzip", innerZip.path, "inner_src"], cwd: dir)

        // 再造外层，把内层包塞进去
        let outerSrc = dir.appendingPathComponent("outer_src", isDirectory: true)
        try? fm.createDirectory(at: outerSrc, withIntermediateDirectories: true)
        try? fm.copyItem(at: innerZip, to: outerSrc.appendingPathComponent("inner.zip"))
        try? "外层文档".write(to: outerSrc.appendingPathComponent("readme.txt"),
                             atomically: true, encoding: .utf8)
        let outerZip = dir.appendingPathComponent("outer.zip")
        _ = sh(["a", "-tzip", outerZip.path, "outer_src"], cwd: dir)

        var settings = BatchSettings()
        settings.autoNested = true
        let jobs = [Job(sources: [outerZip], kind: .extract)]
        let result = drive(jobs, settings: settings)

        var ok = result.failed == 0
        // 队列应从 1 扩展为 2（外层 + 内层）
        if result.jobs.count != 2 {
            ok = false
            print("    ✗ 期望队列扩展为 2 个任务，实际 \(result.jobs.count)")
        }
        // 找 deep.txt
        let found = findFile(named: "deep.txt", in: dir)
        if found == nil { ok = false; print("    ✗ 没找到最深层文件 deep.txt") }
        print(ok ? "    ✓ 队列自动扩展为 \(result.jobs.count) 个，深层文件已解出"
                 : "    ✗ 失败")
        print("")
        return ok ? 0 : 1
    }

    // MARK: 场景 3：给已有 ZIP 加密码

    private static func reencrypt() -> Int {
        print("[3] 重新加密已有 ZIP")
        let dir = root.appendingPathComponent("reencrypt", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let src = dir.appendingPathComponent("src", isDirectory: true)
        try? fm.createDirectory(at: src, withIntermediateDirectories: true)
        try? "机密内容".write(to: src.appendingPathComponent("保密文档.txt"),
                             atomically: true, encoding: .utf8)
        let plain = dir.appendingPathComponent("plain.zip")
        _ = sh(["a", "-tzip", plain.path, src.path])

        let before = Engine.listEntries(plain, password: nil)
        let beforePaths = before.map { $0.path }.sorted()

        var settings = BatchSettings()
        settings.password = "Test123456"
        settings.strongEncryption = true
        let jobs = [Job(sources: [plain], kind: .reencrypt)]
        let result = drive(jobs, settings: settings)

        var ok = result.failed == 0
        if !ok, let msg = jobs.first?.message { print("    ✗ \(msg)") }

        // 验证：文件仍在原位、已被加密、路径结构未被多套一层
        if !fm.fileExists(atPath: plain.path) { ok = false; print("    ✗ 原文件不见了") }
        let after = Engine.listEntries(plain, password: "Test123456")
        let afterPaths = after.map { $0.path }.sorted()
        let encrypted = after.filter { !$0.isDirectory && $0.encrypted }.count
        let totalFiles = after.filter { !$0.isDirectory }.count

        if encrypted == 0 { ok = false; print("    ✗ 条目没有被加密") }
        if totalFiles > 0 && encrypted < totalFiles {
            ok = false; print("    ✗ 只加密了 \(encrypted)/\(totalFiles) 个条目")
        }
        if beforePaths != afterPaths {
            ok = false
            print("    ✗ 包内路径结构变了（重打包多套了一层）")
            print("      原: \(beforePaths)")
            print("      新: \(afterPaths)")
        }
        // 用密码能否取回内容
        let probe = dir.appendingPathComponent("probe", isDirectory: true)
        _ = sh(["x", "-pTest123456", "-o\(probe.path)", plain.path])
        if !fm.fileExists(atPath: probe.appendingPathComponent("src/保密文档.txt").path),
           findFile(named: "保密文档.txt", in: probe) == nil {
            ok = false; print("    ✗ 用密码解不出原内容")
        }

        print(ok ? "    ✓ 已加密（AES-256），路径结构不变，可正常解出" : "    ✗ 失败")
        print("")
        return ok ? 0 : 1
    }

    // MARK: 驱动

    private struct Result { let ok: Int; let failed: Int; let jobs: [Job] }

    private static func drive(_ jobs: [Job], settings: BatchSettings) -> Result {
        let runner = BatchRunner()
        var done = false
        var okCount = 0
        var failCount = 0
        var jobsRef = jobs

        runner.onJobsChanged = { jobsRef = $0 }
        runner.onComplete = { ok, failed in
            okCount = ok
            failCount = failed
            done = true
        }
        runner.run(jobs, settings: settings)
        // 等回调（BatchRunner 在 main queue 上通知）
        let deadline = Date(timeIntervalSinceNow: 120)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        if !done { print("    ✗ 超时") }
        return Result(ok: okCount, failed: failCount, jobs: jobsRef)
    }

    // MARK: 工具

    @discardableResult
    private static func sh(_ args: [String], cwd: URL? = nil) -> String {
        let p = Process()
        p.executableURL = Engine.binary
        p.arguments = args + ["-y", "-bd"]
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    /// 在指定目录建一个 zip，entries 为「相对路径: 内容」
    private static func makeZip(at url: URL, entries: [String: String]) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("_mk_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (name, body) in entries {
            let f = tmp.appendingPathComponent(name)
            try? fm.createDirectory(at: f.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? body.write(to: f, atomically: true, encoding: .utf8)
        }
        let tops = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
        let p = Process()
        p.executableURL = Engine.binary
        var a = ["a", "-tzip", url.path]
        a.append(contentsOf: tops)
        p.arguments = a + ["-y", "-bd"]
        p.currentDirectoryURL = tmp
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
    }

    private static func make7z(at url: URL) {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("_mk7_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? "七z内容".write(to: tmp.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = Engine.binary
        p.arguments = ["a", "-t7z", url.path, "a.txt", "-y", "-bd"]
        p.currentDirectoryURL = tmp
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? fm.removeItem(at: tmp)
    }

    /// 手工造一个「Windows 风格」zip：文件名按 GBK 编码且不设 UTF-8 标志位（bit 11）。
    /// 这正是 macOS 上 7zz 会解成 U+FFFD 的那类包，用来验证 ZipNameFix。
    private static func makeGBKZip(at url: URL, entries: [(String, String)]) {
        let gbk = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        var local = Data(), central = Data()
        for (name, body) in entries {
            guard let nameBytes = name.data(using: gbk) else { continue }
            let data = Data(body.utf8)
            let crc = crc32(data)
            let n = UInt16(nameBytes.count)

            var lh = Data()
            lh.append(contentsOf: le32(0x0403_4b50))
            lh.append(contentsOf: le16(20))
            lh.append(contentsOf: le16(0))          // flags: 无 0x800
            lh.append(contentsOf: le16(0))          // method: store
            lh.append(contentsOf: le16(0))          // time
            lh.append(contentsOf: le16(0))          // date
            lh.append(contentsOf: le32(crc))
            lh.append(contentsOf: le32(UInt32(data.count)))
            lh.append(contentsOf: le32(UInt32(data.count)))
            lh.append(contentsOf: le16(n))
            lh.append(contentsOf: le16(0))
            let offset = UInt32(local.count)
            local.append(lh); local.append(nameBytes); local.append(data)

            var ch = Data()
            ch.append(contentsOf: le32(0x0201_4b50))
            ch.append(contentsOf: le16(20))         // version made by
            ch.append(contentsOf: le16(20))         // version needed
            ch.append(contentsOf: le16(0))          // flags
            ch.append(contentsOf: le16(0))          // method
            ch.append(contentsOf: le16(0))
            ch.append(contentsOf: le16(0))
            ch.append(contentsOf: le32(crc))
            ch.append(contentsOf: le32(UInt32(data.count)))
            ch.append(contentsOf: le32(UInt32(data.count)))
            ch.append(contentsOf: le16(n))
            ch.append(contentsOf: le16(0))          // extra
            ch.append(contentsOf: le16(0))          // comment
            ch.append(contentsOf: le16(0))          // disk
            ch.append(contentsOf: le16(0))          // internal attr
            ch.append(contentsOf: le32(0))          // external attr
            ch.append(contentsOf: le32(offset))
            central.append(ch); central.append(nameBytes)
        }
        var out = local
        let cdOffset = UInt32(out.count)
        out.append(central)
        var eocd = Data()
        eocd.append(contentsOf: le32(0x0605_4b50))
        eocd.append(contentsOf: le16(0))
        eocd.append(contentsOf: le16(0))
        eocd.append(contentsOf: le16(UInt16(entries.count)))
        eocd.append(contentsOf: le16(UInt16(entries.count)))
        eocd.append(contentsOf: le32(UInt32(central.count)))
        eocd.append(contentsOf: le32(cdOffset))
        eocd.append(contentsOf: le16(0))
        out.append(eocd)
        try? out.write(to: url)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8(v >> 8)]
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static func findFile(named name: String, in dir: URL) -> URL? {
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
