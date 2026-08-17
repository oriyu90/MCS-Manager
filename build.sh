#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MCServerManager"
ARCH=$(uname -m)   # arm64 on Apple Silicon, x86_64 on Intel

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  MC Server Manager ビルド"
echo "  アーキテクチャ: $ARCH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

cd "$SCRIPT_DIR"

# ── 1. ビルド ──────────────────────────────
echo ""
echo "▶ swift build (release) ..."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/mcs-clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/mcs-swift-module-cache"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
swift build --disable-sandbox -c release --arch "$ARCH" 2>&1

BINARY="$SCRIPT_DIR/.build/release/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "❌ バイナリが見つかりません: $BINARY"
    exit 1
fi

# ── 2. .app バンドル作成 ──────────────────
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
echo ""
echo "▶ $APP_NAME.app を構成中..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/"
for resource_bundle in "$SCRIPT_DIR"/.build/release/*.bundle; do
    if [[ -d "$resource_bundle" ]]; then
        cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"
        for localized_dir in "$resource_bundle"/*.lproj; do
            [[ -d "$localized_dir" ]] && cp -R "$localized_dir" "$APP_BUNDLE/Contents/Resources/"
        done
    fi
done

# ── 3. Info.plist ────────────────────────
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# ── 4. アドホック署名 ──────────────────────
echo ""
echo "▶ アドホック署名中..."
codesign --force --deep --sign - "$APP_BUNDLE"

# ── 5. 完了 ───────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ ビルド完了"
echo ""
echo "  📦 場所: $APP_BUNDLE"
echo ""
echo "  起動:       open '$APP_BUNDLE'"
echo "  インストール: cp -r '$APP_BUNDLE' /Applications/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
