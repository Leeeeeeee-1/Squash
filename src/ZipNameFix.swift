import Foundation

/// ZIP 文件名编码修复。
///
/// 背景：Windows 资源管理器「发送到 → 压缩文件夹」写出的 zip 不设 UTF-8 标志位
/// （general purpose bit 11 / 0x800），名字按系统 OEM 代码页（简体中文 = GBK）存。
/// macOS 上的 7zz 对这类名字一律按 UTF-8 解，每个非法字节都变成 U+FFFD，原始字节
/// 直接丢失——事后改名救不回来。实测 `-mcp=936` 在这个移植版上不生效（无输出差异）。
///
/// 唯一可靠的解法是解压前把包体重写一遍：条目名转成 UTF-8 并补上 0x800 标志，
/// 压缩数据原样搬运（不解压、不重压缩、不碰 CRC），因此对 AES 加密包同样安全。
enum ZipNameFix {

    struct Prepared {
        let url: URL        // 真正交给 7zz 的路径
        let temp: URL?      // 修复产生的临时包，用完要删
        let note: String?   // 给用户看的说明
    }

    /// 需要对外的唯一入口。任何解析失败都静默回退到原包，绝不阻断解压。
    static func prepare(_ src: URL) -> Prepared {
        guard src.pathExtension.lowercased() == "zip" else {
            return Prepared(url: src, temp: nil, note: nil)
        }
        if let fixed = makeUTF8Copy(of: src) {
            return Prepared(url: fixed, temp: fixed, note: "已修正文件名编码")
        }
        return Prepared(url: src, temp: nil, note: nil)
    }

    // MARK: - 入口

    private static func makeUTF8Copy(of src: URL) -> URL? {
        guard let entries = readEntries(src) else { return nil }

        // 判断有没有需要修的名字
        var needsFix = false
        for e in entries where e.flags & 0x800 == 0 {
            if e.name.allSatisfy({ $0 < 0x80 }) { continue }        // 纯 ASCII，随便解都对
            if String(data: e.name, encoding: .utf8) != nil { continue } // 本来就是 UTF-8 字节，只是没打标志
            needsFix = true
            break
        }
        guard needsFix else { return nil }

        // 猜编码：整包里所有非 ASCII 名字必须都能解通
        guard let enc = detectEncoding(entries) else { return nil }

        var plan = entries
        for i in plan.indices {
            if plan[i].flags & 0x800 != 0 { continue }
            guard plan[i].name.contains(where: { $0 >= 0x80 }) else { continue }
            guard let text = String(data: plan[i].name, encoding: enc),
                  let utf8 = text.precomposedStringWithCanonicalMapping.data(using: .utf8)
            else { return nil }
            plan[i].newName = utf8
        }

        return rebuild(src: src, entries: plan)
    }

    private static func detectEncoding(_ entries: [Entry]) -> String.Encoding? {
        let candidates: [String.Encoding] = [gb18030, big5, shiftJIS]
        for enc in candidates {
            var ok = true
            for e in entries where e.flags & 0x800 == 0 && e.name.contains(where: { $0 >= 0x80 }) {
                guard let s = String(data: e.name, encoding: enc), !s.contains("\u{FFFD}") else {
                    ok = false
                    break
                }
            }
            if ok { return enc }
        }
        return nil
    }

    // MARK: - 结构解析

    fileprivate struct Entry {
        var flags: UInt16
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var csize: UInt32
        var usize: UInt32
        var versionMadeBy: UInt16
        var versionNeeded: UInt16
        var diskStart: UInt16
        var intAttr: UInt16
        var extAttr: UInt32
        var name: Data
        var extra: Data
        var comment: Data
        var localOffset: UInt32
        var newName: Data = Data()
        var newLocalOffset: UInt32 = 0
    }

    private static func readEntries(_ src: URL) -> [Entry]? {
        guard let fh = try? FileHandle(forReadingFrom: src) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() , size > 22 else { return nil }

        // 1. 找 EOCD（从尾部往前扫）
        let tailLen = Int(min(size, 66_560))
        guard (try? fh.seek(toOffset: size - UInt64(tailLen))) != nil,
              let tail = try? fh.read(upToCount: tailLen), tail.count == tailLen
        else { return nil }

        var eocd = -1
        var i = tailLen - 22
        while i >= 0 {
            if u32(tail, i) == Sigs.eocd, i + 22 + Int(u16(tail, i + 20)) == tailLen {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let count = Int(u16(tail, eocd + 10))
        let cdSize = Int(u32(tail, eocd + 12))
        let cdOffset = Int(u32(tail, eocd + 16))
        // zip64 走另一套结构，这里不处理，直接放行（回退原包）
        guard count != 0xFFFF, cdSize != -1, cdOffset != -1, count > 0,
              cdOffset + cdSize <= Int(size), cdSize > 0 else { return nil }
        let comment = bytes(tail, eocd + 22, Int(u16(tail, eocd + 20)))

        // 2. 读中央目录
        guard (try? fh.seek(toOffset: UInt64(cdOffset))) != nil,
              let cd = try? fh.read(upToCount: cdSize), cd.count == cdSize
        else { return nil }

        var out: [Entry] = []
        var p = 0
        while p + 46 <= cdSize {
            guard u32(cd, p) == Sigs.central else { return nil }
            let flags = u16(cd, p + 8)
            let method = u16(cd, p + 10)
            let csize = u32(cd, p + 20)
            let usize = u32(cd, p + 24)
            let nameLen = Int(u16(cd, p + 28))
            let extraLen = Int(u16(cd, p + 30))
            let cmtLen = Int(u16(cd, p + 32))
            let localOffset = u32(cd, p + 42)
            let end = p + 46 + nameLen + extraLen + cmtLen
            guard end <= cdSize else { return nil }
            // 4GB 以上走 zip64 扩展字段，放弃
            guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else {
                return nil
            }
            var e = Entry(
                flags: flags, method: method,
                time: u16(cd, p + 12), date: u16(cd, p + 14),
                crc: u32(cd, p + 16), csize: csize, usize: usize,
                versionMadeBy: u16(cd, p + 4), versionNeeded: u16(cd, p + 6),
                diskStart: u16(cd, p + 34), intAttr: u16(cd, p + 36), extAttr: u32(cd, p + 38),
                name: bytes(cd, p + 46, nameLen),
                extra: bytes(cd, p + 46 + nameLen, extraLen),
                comment: bytes(cd, p + 46 + nameLen + extraLen, cmtLen),
                localOffset: localOffset
            )
            if e.newName.isEmpty { e.newName = e.name }
            out.append(e)
            p = end
        }
        guard out.count == count else { return nil }
        // EOCD 注释要原样带过去，先挂在最后一个条目上借位传递
        lastComment = comment
        return out
    }

    /// EOCD 尾部注释（rebuild 时写回）
    private static var lastComment = Data()

    // MARK: - 重写

    private static func rebuild(src: URL, entries: [Entry]) -> URL? {
        guard let inFH = try? FileHandle(forReadingFrom: src) else { return nil }
        defer { try? inFH.close() }
        guard let fileSize = try? inFH.seekToEnd() else { return nil }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("squash-fix-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        guard let outFH = try? FileHandle(forWritingTo: dst) else { return nil }
        defer { try? outFH.close() }

        var writeOffset = 0
        func write(_ d: Data) {
            try? outFH.write(contentsOf: d)
            writeOffset += d.count
        }

        var plan = entries
        // 按物理顺序走，条目之间的空隙（数据描述符、自解压头）原样搬过去
        let order = plan.indices.sorted { plan[$0].localOffset < plan[$1].localOffset }
        var cursor = 0

        for idx in order {
            let start = Int(plan[idx].localOffset)
            guard start >= cursor, start + 30 <= Int(fileSize) else { return fail(dst) }

            // 空隙
            if start > cursor {
                guard let gap = copy(inFH, from: cursor, count: start - cursor) else { return fail(dst) }
                write(gap)
            }

            guard (try? inFH.seek(toOffset: UInt64(start))) != nil,
                  let lh = try? inFH.read(upToCount: 30), lh.count == 30,
                  u32(lh, 0) == Sigs.local
            else { return fail(dst) }
            let nameLen = Int(u16(lh, 26))
            let extraLen = Int(u16(lh, 28))
            guard let nameAndExtra = try? inFH.read(upToCount: nameLen + extraLen),
                  nameAndExtra.count == nameLen + extraLen
            else { return fail(dst) }
            let localExtra = bytes(nameAndExtra, nameLen, extraLen)
            let dataStart = start + 30 + nameLen + extraLen
            let csize = Int(plan[idx].csize)
            guard dataStart + csize <= Int(fileSize) else { return fail(dst) }

            let newExtra = strip(localExtra, ids: [0x0001, 0x7075])
            plan[idx].newLocalOffset = UInt32(writeOffset)
            plan[idx].flags |= 0x800

            var h = Data()
            h.append(le32(Sigs.local))
            h.append(le16(u16(lh, 4)))                 // version needed
            h.append(le16(plan[idx].flags))
            h.append(le16(plan[idx].method))
            h.append(le16(plan[idx].time))
            h.append(le16(plan[idx].date))
            h.append(le32(plan[idx].crc))
            h.append(le32(plan[idx].csize))
            h.append(le32(plan[idx].usize))
            h.append(le16(UInt16(plan[idx].newName.count)))
            h.append(le16(UInt16(newExtra.count)))
            h.append(plan[idx].newName)
            h.append(newExtra)
            write(h)

            guard let body = copy(inFH, from: dataStart, count: csize) else { return fail(dst) }
            write(body)
            cursor = dataStart + csize
        }

        if cursor < Int(fileSize) {
            guard let tail = copy(inFH, from: cursor, count: Int(fileSize) - cursor) else {
                return fail(dst)
            }
            write(tail)
        }

        // 新的中央目录
        let cdOffset = writeOffset
        for e in plan {
            let extra = strip(e.extra, ids: [0x0001, 0x7075])
            var h = Data()
            h.append(le32(Sigs.central))
            h.append(le16(e.versionMadeBy))
            h.append(le16(e.versionNeeded))
            h.append(le16(e.flags))
            h.append(le16(e.method))
            h.append(le16(e.time))
            h.append(le16(e.date))
            h.append(le32(e.crc))
            h.append(le32(e.csize))
            h.append(le32(e.usize))
            h.append(le16(UInt16(e.newName.count)))
            h.append(le16(UInt16(extra.count)))
            h.append(le16(UInt16(e.comment.count)))
            h.append(le16(e.diskStart))
            h.append(le16(e.intAttr))
            h.append(le32(e.extAttr))
            h.append(le32(e.newLocalOffset))
            h.append(e.newName)
            h.append(extra)
            h.append(e.comment)
            write(h)
        }
        let cdSize = writeOffset - cdOffset

        var eocd = Data()
        eocd.append(le32(Sigs.eocd))
        eocd.append(le16(0))
        eocd.append(le16(0))
        eocd.append(le16(UInt16(plan.count)))
        eocd.append(le16(UInt16(plan.count)))
        eocd.append(le32(UInt32(cdSize)))
        eocd.append(le32(UInt32(cdOffset)))
        eocd.append(le16(UInt16(lastComment.count)))
        eocd.append(lastComment)
        write(eocd)

        return dst
    }

    private static func fail(_ dst: URL) -> URL? {
        try? FileManager.default.removeItem(at: dst)
        return nil
    }

    private static func copy(_ fh: FileHandle, from: Int, count: Int) -> Data? {
        guard count >= 0, (try? fh.seek(toOffset: UInt64(from))) != nil else { return nil }
        var out = Data()
        out.reserveCapacity(count)
        var left = count
        while left > 0 {
            let chunk = min(left, 1 << 20)
            guard let d = try? fh.read(upToCount: chunk), !d.isEmpty else { return nil }
            out.append(d)
            left -= d.count
        }
        return out
    }

    /// 去掉指定的 extra field（0x0001 = zip64，0x7075 = Unicode Path，都指向旧名字）
    private static func strip(_ extra: Data, ids: [UInt16]) -> Data {
        var out = Data()
        var p = 0
        let n = extra.count
        while p + 4 <= n {
            let id = u16(extra, p)
            let len = Int(u16(extra, p + 2))
            guard p + 4 + len <= n else { return extra }   // 结构异常就不动
            if !ids.contains(id) {
                out.append(extra.subdata(in: (extra.startIndex + p)..<(extra.startIndex + p + 4 + len)))
            }
            p += 4 + len
        }
        return out
    }

    // MARK: - 小工具

    private enum Sigs {
        static let local: UInt32 = 0x0403_4b50
        static let central: UInt32 = 0x0201_4b50
        static let eocd: UInt32 = 0x0605_4b50
    }

    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    private static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
    private static let shiftJIS = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)))

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let s = d.startIndex + i
        return UInt16(d[s]) | (UInt16(d[s + 1]) << 8)
    }

    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return UInt32(d[s]) | (UInt32(d[s + 1]) << 8)
            | (UInt32(d[s + 2]) << 16) | (UInt32(d[s + 3]) << 24)
    }

    private static func bytes(_ d: Data, _ i: Int, _ n: Int) -> Data {
        guard n > 0 else { return Data() }
        let s = d.startIndex + i
        guard s + n <= d.endIndex else { return Data() }
        return d.subdata(in: s..<(s + n))
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xff), UInt8(v >> 8)])
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
              UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }
}
