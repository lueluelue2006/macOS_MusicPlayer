#!/bin/bash

# 音乐播放器 DMG 打包脚本
set -e

echo "🎵 开始创建 DMG 安装包..."

# 以脚本所在目录为工作目录，避免外部 cwd 影响
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 配置参数（基于脚本目录）
APP_NAME="MusicPlayer"
VERSION="3.4"
DMG_NAME="MusicPlayer-v${VERSION}"
SOURCE_APP="${SCRIPT_DIR}/MusicPlayer.app"
DMG_TEMP_DIR="${SCRIPT_DIR}/dmg-temp"
DMG_CONTENTS_DIR="${SCRIPT_DIR}/dmg-contents"

# 清理之前的临时文件
echo "🧹 清理临时文件..."
rm -rf "$DMG_TEMP_DIR"
rm -f "${DMG_NAME}.dmg"

# 检查源应用是否存在
if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ 错误：找不到 $SOURCE_APP"
    echo "请先运行 ./build.sh 构建应用"
    exit 1
fi

# 创建临时DMG目录
echo "📁 创建DMG内容..."
mkdir -p "$DMG_TEMP_DIR"

# 复制应用到临时目录
echo "📱 复制应用文件..."
cp -R "$SOURCE_APP" "$DMG_TEMP_DIR/"

# 创建Applications符号链接
echo "🔗 创建 Applications 链接..."
ln -sf /Applications "$DMG_TEMP_DIR/Applications"

# 复制 README（优先根目录 readme.txt，其次 dmg-contents/README.txt，最后生成最小版本）
if [ -f "./readme.txt" ]; then
    echo "📄 复制根目录 readme.txt..."
    cp "./readme.txt" "$DMG_TEMP_DIR/README.txt"
elif [ -f "$DMG_CONTENTS_DIR/README.txt" ]; then
    echo "📄 复制 dmg-contents/README.txt..."
    cp "$DMG_CONTENTS_DIR/README.txt" "$DMG_TEMP_DIR/README.txt"
else
    echo "📄 生成最小 README..."
    cat > "$DMG_TEMP_DIR/README.txt" <<EOF
🎵 音乐播放器 - MusicPlayer $VERSION

• 支持静态与动态歌词显示（.lrc）
• 常见音频格式：MP3, WAV, M4A, AAC, FLAC, AIFF, CAF
• 安装：将 MusicPlayer.app **拖入** Applications
• 首次运行受阻：系统设置 → 隐私与安全性 → 仍要打开；或在终端执行
  xattr -dr com.apple.quarantine /Applications/MusicPlayer.app
EOF
fi

# 复制更新日志为 change_log.txt（从 CHANGELOG.md 转为纯文本）
if [ -f "$DMG_CONTENTS_DIR/CHANGELOG.md" ]; then
    echo "📝 复制更新日志为 change_log.txt..."
    # 去掉 Markdown 标题井号，保留其余内容
    sed 's/^#\+ \?//g' "$DMG_CONTENTS_DIR/CHANGELOG.md" > "$DMG_TEMP_DIR/change_log.txt"
fi

# 创建DMG
echo "💿 创建 DMG 文件..."
hdiutil create -volname "$APP_NAME" \
               -srcfolder "$DMG_TEMP_DIR" \
               -ov \
               -format UDZO \
               -imagekey zlib-level=9 \
               "${DMG_NAME}.dmg"

# 清理临时文件
echo "🧹 清理临时文件..."
rm -rf "$DMG_TEMP_DIR"

# 获取DMG大小
DMG_SIZE=$(du -h "${DMG_NAME}.dmg" | cut -f1)

echo "✅ DMG 创建完成！"
echo ""
echo "📦 文件信息："
echo "   名称: ${DMG_NAME}.dmg"
echo "   大小: $DMG_SIZE"
echo "   位置: $(pwd)/${DMG_NAME}.dmg"
echo ""
echo "🚀 使用方法："
echo "   1. 双击 ${DMG_NAME}.dmg 挂载"
echo "   2. 将 MusicPlayer.app 拖拽到 Applications 文件夹"
echo "   3. 从 Applications 文件夹启动应用"
echo ""
echo "💡 分发提示："
echo "   - 可以直接分享这个 DMG 文件"
echo "   - 用户双击即可安装"
echo "   - 支持 macOS 13.0+ (Apple Silicon & Intel)"
