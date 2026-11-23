#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodePilot"
BUILD_CONFIG="${1:-release}"
OUT_DIR="${ROOT_DIR}/.build/${BUILD_CONFIG}"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

"${ROOT_DIR}/scripts/build.sh" "${BUILD_CONFIG}"

echo "==> Assembling ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Frameworks" "${APP_BUNDLE}/Contents/Resources"

cp "${OUT_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "${OUT_DIR}/libCodePilotCore.dylib" "${APP_BUNDLE}/Contents/Frameworks/libCodePilotCore.dylib"
cp "${ROOT_DIR}/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if [ -f "${ROOT_DIR}/Resources/AppIcon.icns" ]; then
  cp "${ROOT_DIR}/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi
if [ -d "${ROOT_DIR}/Resources/Sounds" ]; then
  mkdir -p "${APP_BUNDLE}/Contents/Resources/Sounds"
  cp "${ROOT_DIR}/Resources/Sounds/"*.wav "${APP_BUNDLE}/Contents/Resources/Sounds/" 2>/dev/null || true
fi

echo "==> Ad-hoc signing ${APP_BUNDLE}..."
codesign --force --sign - "${APP_BUNDLE}/Contents/Frameworks/libCodePilotCore.dylib"
codesign --force --deep --sign - --identifier "com.codepilot.app" "${APP_BUNDLE}"

echo "==> Refreshing LaunchServices registration..."
touch "${APP_BUNDLE}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_BUNDLE}" >/dev/null 2>&1 || true

echo "==> Done: ${APP_BUNDLE}"
