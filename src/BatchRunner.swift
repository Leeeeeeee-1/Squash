import Foundation

// MARK: - 任务模型

enum JobKind {
    case extract          // 解压
    case compress         // 压缩为 ZIP
    case reencrypt        // 给已有压缩包重新加密（解包 → 重打包 → 覆盖）
}

enum JobState {
    case pending, running, done, failed, skipped
}

final class Job {
    let id = UUID()
    /// 压缩任务可以是多个源（合并成一个包），解压/重新加密只有一个
    let sources: [URL]
    let kind: JobKind
    var state: JobState = .pending
    var progress: Int = 0
    var output: URL?
    var message: String = ""
    /// 嵌套层数：0 = 用户直接拖进来的包
    var depth: Int = 0

    var source: URL { sources[0] }

    var displayName: String {
        sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) 项合并压缩"
    }

    init(sources: [URL], kind: JobKind, depth: Int = 0) {
        self.sources = sources
        self.kind = kind
        self.depth = depth
    }
}

struct BatchSettings {
    var level = 5
    var password = ""
    var strongEncryption = false
    /// 自动继续解压嵌套压缩包
    var autoNested = false
    /// 嵌套递归上限，防压缩炸弹
    var maxDepth = 3
    /// 重新加密时是否保留原文件
    var keepOriginal = false
}

// MARK: - 串行执行器

/// 所有任务串行执行。7zz 本身是多线程的，串行足够快，
/// 且避免多个进程抢磁盘把机械盘拖死。
final class BatchRunner {

    private(set) var jobs: [Job] = []
    private var settings = BatchSettings()
    private var process: Process?
    private var cursor = 0
    private var cancelled = false
    private var finished = false
    private var tempDirs: [URL] = []

    /// 单个任务状态变化
    var onJobUpdate: ((Job) -> Void)?
    /// 队列长度变化（嵌套解压会动态追加任务）
    var onJobsChanged: (([Job]) -> Void)?
    /// 总进度（0–100）+ 当前任务描述
    var onProgress: ((Double, String) -> Void)?
    /// 全部结束：成功数、失败数
    var onComplete: ((Int, Int) -> Void)?

    var isRunning: Bool { process != nil }

    // MARK: 启动

    func run(_ jobs: [Job], settings: BatchSettings) {
        cleanupTemp()
        self.jobs = jobs
        self.settings = settings
        self.cursor = 0
        self.cancelled = false
        self.finished = false
        advance()
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        process?.terminate()
        process = nil
        for job in jobs {
            switch job.state {
            case .running:
                job.state = .failed
                job.message = "已取消"
            case .pending:
                job.state = .skipped
            default:
                break
            }
            onJobUpdate?(job)
        }
        finish()
    }

    // MARK: 调度

    private func advance() {
        guard !cancelled else { finish(); return }
        guard cursor < jobs.count else { finish(); return }

        let job = jobs[cursor]
        job.state = .running
        job.progress = 0
        onJobUpdate?(job)
        reportProgress(job)

        switch job.kind {
        case .extract:       runExtract(job)
        case .compress:      runCompress(job)
        case .reencrypt:     runReencrypt(job)
        }
    }

    private func next() {
        cursor += 1
        advance()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        cleanupTemp()
        let failed = jobs.filter { $0.state == .failed }.count
        let ok = jobs.filter { $0.state == .done }.count
        onComplete?(ok, failed)
    }

    private func reportProgress(_ job: Job) {
        let total = Double(jobs.count)
        guard total > 0 else { return }
        let settled = Double(jobs.prefix(max(cursor, 0)).filter {
            $0.state == .done || $0.state == .failed || $0.state == .skipped
        }.count)
        let value = (settled + Double(job.progress) / 100.0) / total * 100.0
        let label = jobs.count > 1
            ? "\(min(cursor + 1, jobs.count))/\(jobs.count) · \(job.displayName)"
            : job.displayName
        onProgress?(min(value, 100), label)
    }

    // MARK: 解压

    private func runExtract(_ job: Job) {
        let dir = job.source.deletingLastPathComponent()
        var base = job.source.pathExtension.isEmpty
            ? job.source.lastPathComponent
            : job.source.deletingPathExtension().lastPathComponent
        if base.isEmpty { base = job.source.lastPathComponent }
        let out = Self.uniqueDirectory(in: dir, base: base)

        // Windows 打的 zip 文件名多是 GBK 且不带 UTF-8 标志，7zz 会解成乱码。
        // 先重写一份标志正确的临时包再解，压缩数据原样搬运，不产生额外开销。
        let prepared = ZipNameFix.prepare(job.source)
        if let temp = prepared.temp { tempDirs.append(temp) }

        // 始终显式传 -p：不给的话 7zz 会转去等 stdin，最后只留一句 Break signaled，
        // 用户完全看不出是「缺密码」还是「密码错」
        var args = ["x", "-o\(out.path)", "-p\(settings.password)"]
        args.append(prepared.url.path)

        process = Engine.run(args, onProgress: { [weak self] pct in
            guard let self else { return }
            job.progress = pct
            self.onJobUpdate?(job)
            self.reportProgress(job)
        }, onFinish: { [weak self] ok, log in
            guard let self else { return }
            self.process = nil

            if ok {
                job.state = .done
                job.output = out
                job.progress = 100
                job.message = prepared.note ?? ""
                self.onJobUpdate?(job)
                // 嵌套解压：扫描刚解出来的目录
                if self.settings.autoNested {
                    self.enqueueNested(inside: out, from: job)
                }
                self.next()
            } else {
                try? FileManager.default.removeItem(at: out)
                job.state = .failed
                job.message = Self.failureMessage(log, password: settings.password)
                self.onJobUpdate?(job)
                self.next()
            }
        })
    }

    /// 把 7zz 的原始报错翻译成用户能直接行动的一句话
    static func failureMessage(_ log: String, password: String) -> String {
        if log.contains("Wrong password") || log.contains("Wrong Password") {
            // 没输密码和密码输错是两回事，别都归到「密码错误」上
            return password.isEmpty ? "这个压缩包需要密码" : "密码不对，重新输入试试"
        }
        return Engine.humanize(log)
    }

    /// 把解压产物里的压缩包追加进队列
    private func enqueueNested(inside dir: URL, from parent: Job) {
        guard parent.depth + 1 <= settings.maxDepth else { return }
        let found = ArchiveScan.nestedArchives(in: dir)
        guard !found.isEmpty else { return }
        // 插到当前任务之后，保持“解完一层再解下一层”的直觉
        let newJobs = found.map { Job(sources: [$0], kind: .extract, depth: parent.depth + 1) }
        jobs.insert(contentsOf: newJobs, at: cursor + 1)
        onJobsChanged?(jobs)
    }

    // MARK: 压缩

    private func runCompress(_ job: Job) {
        guard let first = job.sources.first else {
            job.state = .failed
            job.message = "没有可压缩的内容"
            onJobUpdate?(job)
            next()
            return
        }
        let dir = first.deletingLastPathComponent()
        let base: String
        if job.sources.count == 1 {
            base = first.pathExtension.isEmpty
                ? first.lastPathComponent
                : first.deletingPathExtension().lastPathComponent
        } else {
            base = dir.lastPathComponent.isEmpty ? "Archive" : dir.lastPathComponent
        }
        let out = Self.uniqueArchive(in: dir, base: base.isEmpty ? "Archive" : base)

        var args = ["a", "-tzip", "-mx=\(settings.level)"]
        if !settings.password.isEmpty {
            args += [settings.strongEncryption ? "-mem=AES256" : "-mem=ZipCrypto",
                     "-p\(settings.password)"]
        }
        args += ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!.Spotlight-V100", "-xr!.Trashes"]
        args.append(out.path)
        args.append(contentsOf: job.sources.map { $0.path })

        process = Engine.run(args, onProgress: { [weak self] pct in
            guard let self else { return }
            job.progress = pct
            self.onJobUpdate?(job)
            self.reportProgress(job)
        }, onFinish: { [weak self] ok, log in
            guard let self else { return }
            self.process = nil
            if ok {
                job.state = .done
                job.output = out
                job.progress = 100
            } else {
                try? FileManager.default.removeItem(at: out)
                job.state = .failed
                job.message = Engine.humanize(log)
            }
            self.onJobUpdate?(job)
            self.next()
        })
    }

    // MARK: 重新加密（给已有压缩包加密码）

    /// 7z 不支持原地改加密属性（实测：对已存在的 zip 追加 -p 只会影响新增条目），
    /// 唯一可靠路径是解包到临时目录再重新打包，然后覆盖原文件。
    private func runReencrypt(_ job: Job) {
        // 已经是加密包的情况先拦下来：改密码需要原密码，只有一个密码字段会误导用户
        let existing = Engine.listEntries(job.source, password: nil)
        if existing.contains(where: { !$0.isDirectory && $0.encrypted }) {
            job.state = .failed
            job.message = "这个包已有密码，改密码需要先解压"
            onJobUpdate?(job)
            next()
            return
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("squash-\(UUID().uuidString)", isDirectory: true)
        let unpacked = tmp.appendingPathComponent("payload", isDirectory: true)
        let repacked = tmp.appendingPathComponent("repacked.zip")
        tempDirs.append(tmp)

        // 1. 解包（同样先修正 GBK 文件名，否则重打包后乱码会被固化下来）
        let prepared = ZipNameFix.prepare(job.source)
        var xArgs = ["x", "-o\(unpacked.path)", "-p\(settings.password)"]
        xArgs.append(prepared.url.path)

        process = Engine.run(xArgs, onProgress: { [weak self] pct in
            guard let self else { return }
            // 解包占前 45%
            job.progress = Int(Double(pct) * 0.45)
            self.onJobUpdate?(job)
            self.reportProgress(job)
        }, onFinish: { [weak self] ok, log in
            guard let self else { return }
            self.process = nil
            guard ok else {
                job.state = .failed
                job.message = job.source.pathExtension.lowercased() == "zip"
                    ? Self.failureMessage(log, password: settings.password)
                    : "只有 ZIP 支持重新加密"
                self.onJobUpdate?(job)
                self.next()
                return
            }

            // 2. 收集顶层条目，在工作目录内用相对路径重打包
            let tops = (try? FileManager.default.contentsOfDirectory(atPath: unpacked.path)) ?? []
            guard !tops.isEmpty else {
                job.state = .failed
                job.message = "压缩包是空的"
                self.onJobUpdate?(job)
                self.next()
                return
            }

            var aArgs = ["a", "-tzip", "-mx=\(self.settings.level)",
                         self.settings.strongEncryption ? "-mem=AES256" : "-mem=ZipCrypto",
                         "-p\(self.settings.password)",
                         "-xr!.DS_Store", "-xr!__MACOSX"]
            aArgs.append(repacked.path)
            aArgs.append(contentsOf: tops)

            self.process = Engine.run(aArgs, workingDirectory: unpacked,
                                      onProgress: { [weak self] pct in
                guard let self else { return }
                job.progress = 45 + Int(Double(pct) * 0.5)
                self.onJobUpdate?(job)
                self.reportProgress(job)
            }, onFinish: { [weak self] ok2, log2 in
                guard let self else { return }
                self.process = nil
                guard ok2 else {
                    job.state = .failed
                    job.message = "重打包失败：\(Engine.humanize(log2))"
                    self.onJobUpdate?(job)
                    self.next()
                    return
                }
                // 3. 覆盖原文件（先改名兜底，成功再删）
                let original = job.source
                let backup = original.deletingLastPathComponent()
                    .appendingPathComponent(".\(original.lastPathComponent).squashbak")
                try? FileManager.default.removeItem(at: backup)
                do {
                    try FileManager.default.moveItem(at: original, to: backup)
                    try FileManager.default.moveItem(at: repacked, to: original)
                    if !self.settings.keepOriginal {
                        try? FileManager.default.removeItem(at: backup)
                    } else {
                        let kept = original.deletingLastPathComponent()
                            .appendingPathComponent(original.deletingPathExtension().lastPathComponent
                                                    + "（未加密）.zip")
                        try? FileManager.default.moveItem(at: backup, to: kept)
                    }
                    job.state = .done
                    job.output = original
                    job.progress = 100
                    job.message = "已加密"
                } catch {
                    // 回滚
                    if FileManager.default.fileExists(atPath: backup.path) {
                        try? FileManager.default.moveItem(at: backup, to: original)
                    }
                    job.state = .failed
                    job.message = "替换原文件失败：\(error.localizedDescription)"
                }
                self.onJobUpdate?(job)
                self.next()
            })
        })
    }

    // MARK: 清理

    private func cleanupTemp() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs.removeAll()
    }

    // MARK: 路径工具

    static func uniqueDirectory(in dir: URL, base: String) -> URL {
        var n = 1
        var url = dir.appendingPathComponent(base)
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(base) \(n)")
        }
        return url
    }

    static func uniqueArchive(in dir: URL, base: String) -> URL {
        var n = 1
        var url = dir.appendingPathComponent("\(base).zip")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(base) \(n).zip")
        }
        return url
    }
}

// MARK: - 归档扫描

enum ArchiveScan {

    /// 用户拖进来时可以「解压」的所有类型。
    /// 含 exe/dll/so/dylib/efi——7zz 能直接展开可执行文件结构，
    /// 取证或样本初筛有用，所以拖入即解压。
    static let extractable: Set<String> = [
        "7z", "zip", "zipx", "rar", "r00", "r01", "r02", "tar", "gz", "bz2", "xz",
        "zst", "lz4", "br", "lzma", "lz", "tgz", "tbz2", "txz", "tlz", "taz",
        "dmg", "iso", "cab", "msi", "wim", "swm", "cpio", "xar", "jar", "war",
        "ear", "ipa", "apk", "appx", "xpi", "arj", "lzh", "lha", "pax", "cpt",
        "spk", "rpm", "deb", "z", "ar", "udf", "vhd", "vhdx", "vmdk", "qcow2",
        "apfs", "hfs", "squashfs", "chm", "nsis", "exe", "dll", "so", "dylib",
        "efi", "img", "raw", "partimg"
    ]

    /// 嵌套解压只认「真正的压缩包」。
    /// 绝不能把 exe/dll 算进来——否则解出一个装满可执行文件的目录后，
    /// 队列会炸成几百个莫名其妙的解包任务。
    static let nestedCandidates: Set<String> = [
        "7z", "zip", "zipx", "rar", "tar", "gz", "bz2", "xz", "zst", "lz4",
        "lzma", "tgz", "tbz2", "txz", "tlz", "taz", "cab", "jar", "war", "ear",
        "ipa", "apk", "appx", "xpi", "wim", "arj", "lzh", "lha", "cpio", "xar",
        "rpm", "deb", "chm"
    ]

    static func isArchive(_ url: URL) -> Bool {
        extractable.contains(url.pathExtension.lowercased())
    }

    /// 找出目录里可以继续解压的压缩包（递归，用于嵌套解压）
    static func nestedArchives(in dir: URL) -> [URL] {
        archives(in: dir, recursive: true).filter {
            nestedCandidates.contains($0.pathExtension.lowercased())
        }
    }

    /// 扫描目录里的压缩包
    static func archives(in dir: URL, recursive: Bool) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: recursive ? [] : [.skipsSubdirectoryDescendants])
        else { return [] }
        for case let url as URL in en {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            // 跳过 macOS 垃圾与分卷副包（r00/r01… 由主包统一处理）
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let ext = url.pathExtension.lowercased()
            if ext.count == 3, ext.hasPrefix("r"), Int(ext.dropFirst()) != nil { continue }
            if isArchive(url) { result.append(url) }
        }
        // 浅层优先
        return result.sorted { $0.pathComponents.count < $1.pathComponents.count }
    }
}
