#!/bin/zsh
set -euo pipefail

configuration="${1:-debug}"
project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/NineBar.app"
stale_file="$app_dir/Contents/Resources/stale-verification.txt"
source_icon="$project_dir/Resources/MenuBarIcon.png"
packaged_icon="$app_dir/Contents/Resources/MenuBarIcon.png"
application_icon="$project_dir/Resources/AppIcon.png"

mkdir -p "$app_dir/Contents/Resources"
: > "$stale_file"

"$project_dir/scripts/build-app.sh" "$configuration" >/dev/null

if [[ -e "$stale_file" ]]; then
    echo "stale bundle file survived rebuild" >&2
    exit 1
fi

[[ -x "$app_dir/Contents/MacOS/NineBar" ]]
[[ -x "$app_dir/Contents/MacOS/NineBarHealthCheck" ]]
codesign --verify --deep --strict --verbose=2 "$app_dir"
plutil -lint "$app_dir/Contents/Info.plist" >/dev/null
plutil -lint "$app_dir"/Contents/Resources/{en,zh-Hans}.lproj/InfoPlist.strings >/dev/null
swift "$project_dir/scripts/verify-menu-bar-icon.swift" \
    "$source_icon" \
    "$packaged_icon" \
    "$application_icon"
