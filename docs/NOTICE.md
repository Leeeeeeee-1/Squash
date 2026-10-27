# 第三方组件声明 / Third-Party Notices

Squash 本身以 MIT 许可发布，但它打包并调用了一个独立的命令行可执行文件。
这部分**不是** MIT，必须单独遵守其原始许可。

---

## 7-Zip (`7zz`)

- **位置**：仓库内 `vendor/7z-mac.tar.xz`（官方原包），构建时解出到 `vendor/7zmac/7zz`，
  再复制到 `Squash.app/Contents/Resources/7zz`
- **版本**：7-Zip (z) 26.05 (arm64)，构建于 2026-10-21
- **来源**：<https://www.7-zip.org/download.html>（`7z2605-mac.tar.xz`）
- **校验**：`sha256 = 12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570`，1,868,068 字节
- **版权**：Copyright (C) 1999-2026 Igor Pavlov
- **许可**：GNU LGPL（大部分代码）+ GNU LGPL 附 unRAR 限制（部分代码）+ BSD 3-clause / BSD 2-clause（部分代码）

仓库只保存官方压缩包、不直接提交 6 MB 的 `7zz` 二进制，构建脚本在缺少引擎时自动解出。

完整许可原文见：

- [`vendor/7zmac/License.txt`](../vendor/7zmac/License.txt)
- 官方页面：<https://www.7-zip.org/license.txt>

### 关于 unRAR 限制

7-Zip 中处理 RAR 格式的代码源自 unRAR，版权归 Alexander Roshal 所有，
其原始许可附带一条限制：**不得用该代码逆向工程 RAR 压缩算法，也不得用它开发 RAR 兼容的压缩器**。
Squash 只用 `7zz` 做**解压**，不实现任何 RAR 压缩，符合该限制。

### 关于二进制再分发

7-Zip 许可要求：以二进制形式再分发时，必须随附本文件中的相关许可信息。
因此 `License.txt` 与 `readme.txt` 一并保留在 `vendor/7zmac/` 下，且不会被构建脚本剥离。

`7zz` 以**独立进程**方式被调用（`Process` + 参数），未与 MIT 部分静态链接，
两者构成「聚合」而非「衍生作品」，因此 MIT 部分不受 LGPL 传染。

---

## Swift / AppKit

Squash 的源码只依赖 macOS 系统自带的 Swift 运行时与 AppKit 框架，未引入任何
第三方 Swift Package、CocoaPod 或静态库。`Package.resolved` 为空是刻意为之。
