#!/bin/bash
# ModelRouter 打包脚本：Release 构建 → 可拖拽安装 DMG（含 Applications 快捷方式）→ 输出到仓库根目录
# 命名＝版本号（读取构建产物 Info.plist 的 CFBundleShortVersionString；真源＝pbxproj MARKETING_VERSION）。
# 不依赖 git（发行仓库与本地 git 独立，2026-10-07 管理员裁定）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DD="$ROOT/.build-release"
OUT=""   # 构建后按产物版本号定名（见下方 VER 行）

echo "==> Release 构建"
xcodebuild -project "$ROOT/ModelRouter.xcodeproj" -scheme ModelRouter \
  -configuration Release -derivedDataPath "$DD" build | tail -3

APP="$DD/Build/Products/Release/ModelRouter.app"
[ -d "$APP" ] || { echo "构建产物缺失: $APP" >&2; exit 1; }
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/ModelRouter-${VER}.dmg"

# 统一 ad-hoc 重签（先内嵌 framework 后 app）：构建期内嵌签名在 LaunchServices 严格启动
# 路径下过不了 Hardened Runtime 的 library validation（dyld 报 Team ID 不一致），一次同身份重签即修
echo "==> 统一重签（adhoc）"
codesign --force --sign - "$APP/Contents/Frameworks/ModelRouterCore.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> 组装 DMG 舞台（app + Applications 快捷方式）"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 生成 DMG: $OUT"
rm -f "$OUT"
hdiutil create -volname "ModelRouter" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null

echo "==> 完成: $OUT"
ls -lh "$OUT"
