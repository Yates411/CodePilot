#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${1:-debug}"
OUT_DIR="${ROOT_DIR}/.build/${BUILD_CONFIG}"
MOD_CACHE="${OUT_DIR}/ModuleCache"
mkdir -p "${OUT_DIR}" "${MOD_CACHE}"

OPT_FLAGS=("-Onone" "-g")
if [[ "${BUILD_CONFIG}" == "release" ]]; then
    OPT_FLAGS=("-O")
fi

CORE_SOURCES=()
while IFS= read -r f; do
    CORE_SOURCES+=("$f")
done < <(find "${ROOT_DIR}/Sources/CodePilotCore" -name '*.swift' | sort)

APP_SOURCES=()
while IFS= read -r f; do
    APP_SOURCES+=("$f")
done < <(find "${ROOT_DIR}/Sources/CodePilot" -name '*.swift' | sort)

echo "==> Compiling CodePilotCore (${BUILD_CONFIG})..."
swiftc \
    -module-cache-path "${MOD_CACHE}" \
    -target arm64-apple-macosx14.0 \
    -swift-version 6 \
    "${OPT_FLAGS[@]}" \
    -framework IOKit \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreServices \
    -framework UserNotifications \
    -framework ServiceManagement \
    -framework Security \
    -framework Foundation \
    -lsqlite3 \
    -emit-module \
    -emit-library \
    -module-name CodePilotCore \
    -emit-module-path "${OUT_DIR}/CodePilotCore.swiftmodule" \
    -Xlinker -install_name -Xlinker "@rpath/libCodePilotCore.dylib" \
    -o "${OUT_DIR}/libCodePilotCore.dylib" \
    "${CORE_SOURCES[@]}"

echo "==> Compiling CodePilot (${BUILD_CONFIG})..."
swiftc \
    -module-cache-path "${MOD_CACHE}" \
    -target arm64-apple-macosx14.0 \
    -swift-version 6 \
    "${OPT_FLAGS[@]}" \
    -parse-as-library \
    -I "${OUT_DIR}" \
    -L "${OUT_DIR}" \
    -lCodePilotCore \
    -Xlinker -rpath -Xlinker "@executable_path" \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -framework SwiftUI \
    -framework AppKit \
    -framework IOKit \
    -framework Foundation \
    -o "${OUT_DIR}/CodePilot" \
    "${APP_SOURCES[@]}"

echo "==> Built: ${OUT_DIR}/CodePilot"
