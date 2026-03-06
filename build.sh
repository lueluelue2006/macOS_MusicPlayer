#!/bin/bash

# macOS 音乐播放器构建脚本
# 使用方法: ./build.sh

set -e

echo "🎵 开始构建 macOS 音乐播放器..."

VERSION="$(tr -d '[:space:]' < VERSION)"
if [[ -z "$VERSION" ]]; then
    echo "❌ 错误: VERSION 文件为空"
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
rm -rf .build
rm -rf MusicPlayer.app

# 构建项目
echo "🔨 构建项目..."
if swift build -c release; then
  echo "✅ SwiftPM 构建成功"
else
  echo "⚠️  SwiftPM 构建失败，尝试使用 --disable-sandbox 重新构建…"
  swift build --disable-sandbox -c release
fi

# 创建应用包结构
echo "📦 创建应用包..."
mkdir -p MusicPlayer.app/Contents/MacOS
mkdir -p MusicPlayer.app/Contents/Resources

# 复制可执行文件
cp .build/release/MusicPlayer MusicPlayer.app/Contents/MacOS/

# 复制应用图标
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns MusicPlayer.app/Contents/Resources/
    echo "📱 应用图标已添加"
else
    echo "⚠️  警告: 未找到 AppIcon.icns 文件"
fi

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

# 尝试进行临时(adhoc)签名以提升通知注册可靠性
echo "🔏 对应用进行临时签名(adhoc)…"
if codesign --force --deep --sign - "MusicPlayer.app" 2>/dev/null; then
  echo "   ✅ 已完成 adhoc 签名"
  # 打印简要签名信息（非致命）
  codesign -dv --verbose=1 MusicPlayer.app 2>&1 | head -n 3 || true
else
  echo "   ⚠️ 未能完成签名（可忽略）。如需通知更稳定，可手动执行："
  echo "      codesign --force --deep --sign - /Applications/MusicPlayer.app"
fi

echo "✅ 构建完成！"
echo ""
echo "📁 应用位置: $(pwd)/MusicPlayer.app"
echo "🚀 运行应用: open MusicPlayer.app"
echo ""
echo "💡 提示:"
echo "   - 双击 MusicPlayer.app 启动应用"
echo "   - 将音频文件拖拽到应用中即可播放"
echo "   - 元数据编辑：蓝色铅笔=直接编辑(M4A/MP4/AAC)，橙色铅笔=生成FFmpeg命令"
echo "   - 歌词嵌入助手：在‘生成FFmpeg命令’页面底部，填入歌曲与.lrc路径，一键复制嵌入命令"
echo "   - Finder 复制完整路径：选中文件后按 Option+Command+C"
echo "   - 支持 MP3, WAV, M4A, AAC, FLAC, AIFF, CAF 格式"
echo "   - 若系统未出现通知授权弹窗，建议将应用移动到 /Applications 后执行："
echo "       xattr -dr com.apple.quarantine /Applications/MusicPlayer.app"
echo "       codesign --force --deep --sign - /Applications/MusicPlayer.app"
echo "     然后在应用内‘设置 → 打开系统通知设置…’中开启通知"
