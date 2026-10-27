#!/bin/zsh
set -e
cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
APP=build/Squash.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Squash</string>
    <key>CFBundleDisplayName</key>       <string>Squash</string>
    <key>CFBundleIdentifier</key>        <string>com.lee.squash</string>
    <key>CFBundleExecutable</key>        <string>Squash</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key>           <string>2</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>压缩归档</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.zip-archive</string>
                <string>org.7-zip.7-zip-archive</string>
                <string>com.rarlab.rar-archive</string>
                <string>public.tar-archive</string>
                <string>org.gnu.gnu-zip-archive</string>
                <string>org.gnu.gnu-zip-tar-archive</string>
                <string>public.bzip2-archive</string>
                <string>public.tar-bzip2-archive</string>
                <string>org.tukaani.xz-archive</string>
                <string>org.tukaani.tar-xz-archive</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>zip</string>
                <string>7z</string>
                <string>rar</string>
                <string>tar</string>
                <string>gz</string>
                <string>tgz</string>
                <string>bz2</string>
                <string>tbz</string>
                <string>tbz2</string>
                <string>xz</string>
                <string>txz</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>任意文件（仅出现在“打开方式”里）</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.item</string>
                <string>public.data</string>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.lee.squash.url</string>
            <key>CFBundleURLSchemes</key>
            <array><string>squash</string></array>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 Squash 解压</string></dict>
            <key>NSMessage</key><string>squashExtract</string>
            <key>NSPortName</key><string>Squash</string>
            <key>NSRequiredContext</key>
            <dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
            <key>NSSendFileTypes</key>
            <array><string>public.item</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>用 Squash 加密码…</string></dict>
            <key>NSMessage</key><string>squashEncrypt</string>
            <key>NSPortName</key><string>Squash</string>
            <key>NSRequiredContext</key>
            <dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
            <key>NSSendFileTypes</key>
            <array><string>public.item</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> swiftc 编译"
swiftc -swift-version 5 -parse-as-library -O \
    -target arm64-apple-macosx13.0 \
    -sdk "$SDK" \
    src/App.swift src/Engine.swift src/ZipNameFix.swift src/BatchRunner.swift src/SelfTest.swift src/MainViewController.swift \
    -o "$APP/Contents/MacOS/Squash"

# 仓库里只放官方原包（1.8 MB），构建时解出引擎，避免把 6 MB 二进制塞进 git。
# sha256 见 docs/NOTICE.md，来自 https://www.7-zip.org/download.html
if [ ! -x vendor/7zmac/7zz ]; then
    echo "==> 解出 7-Zip 引擎"
    mkdir -p vendor/7zmac
    tar -xf vendor/7z-mac.tar.xz -C vendor/7zmac
fi

echo "==> 打包 7zz 引擎"
cp vendor/7zmac/7zz "$APP/Contents/Resources/7zz"
chmod +x "$APP/Contents/Resources/7zz"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP" 2>/dev/null

du -sh "$APP"

echo "==> 完成: $PWD/$APP"
echo "    直接运行：open $APP"

# 只有显式 INSTALL=1 才写 /Applications。
# 开源项目里默认不改别人系统——Finder 服务需要稳定路径，才需要这一步。
if [ "${INSTALL:-0}" = "1" ]; then
    echo "==> 安装到 /Applications（Finder 服务需要稳定路径）"
    pkill -x Squash 2>/dev/null || true
    rm -rf /Applications/Squash.app
    cp -R "$APP" /Applications/Squash.app
    LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    "$LSREG" -f /Applications/Squash.app 2>/dev/null || true
    /System/Library/CoreServices/pbs -read_bundle /Applications/Squash.app >/dev/null 2>&1 || true
    echo "==> 已安装"
fi
