#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/.build/debug"

"${ROOT_DIR}/scripts/build.sh" debug

TEST_SOURCES=()
while IFS= read -r f; do
    TEST_SOURCES+=("$f")
done < <(find "${ROOT_DIR}/Tests/CodePilotTests" -name '*.swift' | sort)

echo "==> Compiling CodePilotTests..."
swiftc \
    -module-cache-path "${OUT_DIR}/ModuleCache" \
    -target arm64-apple-macosx14.0 \
    -swift-version 6 \
    -Onone -g \
    -parse-as-library \
    -I "${OUT_DIR}" \
    -L "${OUT_DIR}" \
    -lCodePilotCore \
    -Xlinker -rpath -Xlinker "${OUT_DIR}" \
    -framework Foundation \
    -lsqlite3 \
    -o "${OUT_DIR}/CodePilotTests" \
    "${TEST_SOURCES[@]}"

echo "==> Running CodePilotTests..."
"${OUT_DIR}/CodePilotTests"
