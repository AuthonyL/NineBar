#!/bin/zsh
# Build NineBar and open it. `./run.sh --install` also copies the app to /Applications.
set -euo pipefail
cd "${0:A:h}"

autoload -Uz is-at-least
swift_version="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
if [[ -z "$swift_version" ]] || ! is-at-least 6.2 "$swift_version"; then
    echo "需要 Swift 6.2 或更高版本。请安装 Xcode，或运行 xcode-select --install。" >&2
    echo "Swift 6.2 or later is required. Install Xcode or run xcode-select --install." >&2
    exit 1
fi

echo "正在构建 NineBar（首次需要几分钟）… / Building NineBar (the first build takes a few minutes)…"
scripts/build-app.sh release

app="dist/NineBar.app"
if [[ "${1:-}" == "--install" ]]; then
    ditto "$app" /Applications/NineBar.app
    app="/Applications/NineBar.app"
fi

# A running copy keeps the old binary, so quit it before opening the new build.
pkill -x NineBar || true
open "$app"
