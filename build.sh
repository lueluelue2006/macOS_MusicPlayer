#!/bin/bash

# macOS 音乐播放器构建脚本
# 使用方法: ./build.sh

set -e

echo "🎵 开始构建 macOS 音乐播放器..."

# 以脚本所在目录为工作目录，避免外部 cwd 影响相对路径清理和产物位置
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ -z "$VERSION" ]]; then
    echo "❌ 错误: VERSION 文件为空"
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "❌ 错误: 发行版只支持 Apple Silicon，请在 M 系列 Mac 上构建"
    exit 1
fi

# 检查 Xcode 是否安装
if ! command -v swift &> /dev/null; then
    echo "❌ 错误: 未找到 Swift。请安装 Xcode Command Line Tools:"
    echo "   xcode-select --install"
    exit 1
fi

# 检查最低 macOS 版本
if [[ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 13 ]]; then
    echo "❌ 错误: 需要 macOS 13 或更高版本"
    exit 1
fi

# 清理之前的构建
echo "🧹 清理之前的构建..."
swift package clean
rm -rf MusicPlayer.app

# 构建项目
echo "🔨 构建项目..."
BUILD_JOBS="${SWIFT_BUILD_JOBS:-1}"
echo "   使用 ${BUILD_JOBS} 个并发编译任务（可通过 SWIFT_BUILD_JOBS 覆盖）"
SWIFT_BUILD_ARGS=(-c release --jobs "${BUILD_JOBS}")

if swift build "${SWIFT_BUILD_ARGS[@]}"; then
  echo "✅ SwiftPM 构建成功"
else
  echo "⚠️  SwiftPM 构建失败，尝试使用 --disable-sandbox 重新构建…"
  swift build --disable-sandbox "${SWIFT_BUILD_ARGS[@]}"
fi

# 创建应用包结构
echo "📦 创建应用包..."
mkdir -p MusicPlayer.app/Contents/MacOS
mkdir -p MusicPlayer.app/Contents/Resources

# 复制可执行文件
cp ".build/release/MusicPlayer" "MusicPlayer.app/Contents/MacOS/"
cp ".build/release/musicplayerctl" "MusicPlayer.app/Contents/MacOS/"

# 复制应用图标
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns MusicPlayer.app/Contents/Resources/
    echo "📱 应用图标已添加"
else
    echo "⚠️  警告: 未找到 AppIcon.icns 文件"
fi

# 复制内置歌手歌单封面。显式校验文件，避免发行包静默退回字母封面。
PLAYLIST_COVER_SOURCE="assets/playlist-covers"
PLAYLIST_COVER_DESTINATION="MusicPlayer.app/Contents/Resources/PlaylistCovers"
PLAYLIST_COVERS=(
    "yang-kun.png"
    "fei-yu-ching.png"
    "stefanie-sun.png"
    "faye-wong.png"
)
PLAYLIST_COVER_ATTRIBUTIONS="ATTRIBUTIONS.txt"
mkdir -p "$PLAYLIST_COVER_DESTINATION"
for cover in "${PLAYLIST_COVERS[@]}"; do
    if [[ ! -f "$PLAYLIST_COVER_SOURCE/$cover" ]]; then
        echo "❌ 错误: 缺少内置歌单封面 $PLAYLIST_COVER_SOURCE/$cover"
        exit 1
    fi
    cp "$PLAYLIST_COVER_SOURCE/$cover" "$PLAYLIST_COVER_DESTINATION/$cover"
done
if [[ ! -f "$PLAYLIST_COVER_SOURCE/$PLAYLIST_COVER_ATTRIBUTIONS" ]]; then
    echo "❌ 错误: 缺少歌单封面许可说明 $PLAYLIST_COVER_SOURCE/$PLAYLIST_COVER_ATTRIBUTIONS"
    exit 1
fi
cp \
    "$PLAYLIST_COVER_SOURCE/$PLAYLIST_COVER_ATTRIBUTIONS" \
    "$PLAYLIST_COVER_DESTINATION/$PLAYLIST_COVER_ATTRIBUTIONS"
echo "🖼️  已添加 ${#PLAYLIST_COVERS[@]} 张内置歌单封面及许可说明"

# 创建 Info.plist
cat > MusicPlayer.app/Contents/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>音乐播放器</string>
    <key>CFBundleExecutable</key>
    <string>MusicPlayer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.lueluelue2006.macosmusicplayer</string>
    <key>CFBundleName</key>
    <string>MusicPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>MusicPlayerApplication</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	    <key>CFBundleVersion</key>
	    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
	    <key>CFBundleDocumentTypes</key>
	    <array>
	        <!-- 可播放的音频格式：作为默认处理程序（Owner） -->
	        <dict>
	            <key>CFBundleTypeName</key>
	            <string>Audio (Common)</string>
	            <key>LSItemContentTypes</key>
	            <array>
	                <string>public.mp3</string>
	                <string>com.apple.m4a-audio</string>
	                <string>public.mpeg-4-audio</string>
	                <string>public.aac-audio</string>
	                <string>com.microsoft.waveform-audio</string>
	                <string>public.aiff-audio</string>
	                <string>public.aifc-audio</string>
	                <string>com.apple.coreaudio-format</string>
	                <string>org.xiph.flac</string>
	            </array>
	            <key>CFBundleTypeRole</key>
	            <string>Viewer</string>
	            <key>LSHandlerRank</key>
            <string>Owner</string>
        </dict>
        <!-- 扩展名匹配（补充），同样作为默认处理程序 -->
        <dict>
            <key>CFBundleTypeExtensions</key>
	            <array>
	                <string>mp3</string>
	                <string>m4a</string>
	                <string>aac</string>
	                <string>wav</string>
	                <string>aif</string>
	                <string>aiff</string>
	                <string>aifc</string>
	                <string>caf</string>
	                <string>flac</string>
	            </array>
	            <key>CFBundleTypeName</key>
	            <string>Audio Extensions</string>
	            <key>CFBundleTypeRole</key>
	            <string>Viewer</string>
	            <key>LSHandlerRank</key>
	            <string>Owner</string>
	        </dict>
	    </array>
</dict>
</plist>
EOF

# 设置可执行权限
chmod +x MusicPlayer.app/Contents/MacOS/MusicPlayer
chmod +x MusicPlayer.app/Contents/MacOS/musicplayerctl

verify_arm64_binary() {
  local binary="$1"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$binary" 2>/dev/null || true)"
  if [[ "$architectures" != "arm64" ]]; then
    echo "❌ 错误: $binary 的架构为 ${architectures:-未知}，发行版要求纯 arm64"
    exit 1
  fi
}

verify_arm64_binary "MusicPlayer.app/Contents/MacOS/MusicPlayer"
verify_arm64_binary "MusicPlayer.app/Contents/MacOS/musicplayerctl"
echo "✅ 已确认 Apple Silicon（arm64）架构"

# 尝试进行临时(adhoc)签名以提升通知注册可靠性
echo "🔏 对应用进行临时签名(adhoc)…"
if codesign --force --deep --sign - "MusicPlayer.app" 2>/dev/null; then
  echo "   ✅ 已完成 adhoc 签名"
  # 打印简要签名信息（非致命）
  codesign -dv --verbose=1 MusicPlayer.app 2>&1 | head -n 3 || true
else
  echo "❌ 错误: 未能完成应用签名，发行包将无法通过校验"
  exit 1
fi

echo "✅ 构建完成！"
echo ""
echo "📁 应用位置: $(pwd)/MusicPlayer.app"
echo "🚀 运行应用: open MusicPlayer.app"
echo ""
echo "💡 提示:"
echo "   - 双击 MusicPlayer.app 启动应用"
echo "   - 将音频文件拖拽到应用中即可播放"
echo "   - 元数据编辑：悬停歌曲行后点击铅笔；不支持直接写入的格式会生成 FFmpeg 命令"
echo "   - 歌词嵌入助手：在‘生成FFmpeg命令’页面底部，填入歌曲与.lrc路径，一键复制嵌入命令"
echo "   - Finder 复制完整路径：选中文件后按 Option+Command+C"
echo "   - 支持 MP3, WAV, M4A, AAC, FLAC, AIFF, CAF 格式"
echo "   - 若系统未出现通知授权弹窗，建议将应用移动到 /Applications 后执行："
echo "       xattr -dr com.apple.quarantine /Applications/MusicPlayer.app"
echo "       codesign --force --deep --sign - /Applications/MusicPlayer.app"
echo "     然后在应用内‘设置 → 打开系统通知设置…’中开启通知"
