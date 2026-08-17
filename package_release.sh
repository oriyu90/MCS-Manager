#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION="1.0.0"
APP_NAME="MCServerManager"
DMG_NAME="MCSManager_v${VERSION}.dmg"
STAGE="${TMPDIR:-/tmp}/mcs-manager-release-${VERSION}"
OUTPUT_DIR="$WORKSPACE_DIR/配布dmg"
SOURCE_OUTPUT="$WORKSPACE_DIR/ビルド用source code/MCSManager_v${VERSION}_Source"

cd "$SCRIPT_DIR"
bash build.sh

rm -rf "$STAGE"
mkdir -p "$STAGE/Source" "$OUTPUT_DIR" "$SOURCE_OUTPUT"
cp -R "$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp -R Sources "$STAGE/Source/"
cp Package.swift build.sh package_release.sh Info.plist README.md LICENSE WebAPI_Spec.txt QUALITY_AUDIT_REPORT.md "$STAGE/Source/"
cp README.md LICENSE QUALITY_AUDIT_REPORT.md "$STAGE/"

rm -rf "$SOURCE_OUTPUT/Sources"
cp -R Sources "$SOURCE_OUTPUT/Sources"
cp Package.swift build.sh package_release.sh Info.plist README.md LICENSE WebAPI_Spec.txt QUALITY_AUDIT_REPORT.md "$SOURCE_OUTPUT/"

rm -f "$OUTPUT_DIR/$DMG_NAME"
hdiutil create -volname "MCS Manager ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"
rm -rf "$STAGE"
echo "$OUTPUT_DIR/$DMG_NAME"
