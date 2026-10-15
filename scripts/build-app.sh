#!/bin/zsh
set -euo pipefail
configuration="${1:-debug}"
project_dir="${0:A:h:h}"
cd "$project_dir"
swift build -c "$configuration" --product NineBar
swift build -c "$configuration" --product NineBarHealthCheck
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
dist_dir="$project_dir/dist"
app_dir="$project_dir/dist/NineBar.app"
expected_app_dir="$project_dir/dist/NineBar.app"
if [[ "$app_dir" != "$expected_app_dir" ]]; then
    echo "refusing to replace unexpected app path: $app_dir" >&2
    exit 1
fi

mkdir -p "$dist_dir"
staging_root="$(mktemp -d "$dist_dir/.ninebar-app.XXXXXX")"
trap 'rm -rf -- "$staging_root"' EXIT
staged_app="$staging_root/NineBar.app"
icon_source="$project_dir/Resources/AppIcon.png"
menu_bar_icon_source="$project_dir/Resources/MenuBarIcon.png"
iconset_dir="$staging_root/NineBar.iconset"

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
install -m 755 "$binary_dir/NineBar" "$staged_app/Contents/MacOS/NineBar"
install -m 755 "$binary_dir/NineBarHealthCheck" "$staged_app/Contents/MacOS/NineBarHealthCheck"
install -m 644 "$project_dir/Resources/Info.plist" "$staged_app/Contents/Info.plist"
for localization in "$project_dir"/Resources/*.lproj; do
    ditto "$localization" "$staged_app/Contents/Resources/${localization:t}"
done
if [[ ! -f "$icon_source" ]]; then
    echo "missing app icon source: $icon_source" >&2
    exit 1
fi
if [[ ! -f "$menu_bar_icon_source" ]]; then
    echo "missing menu bar icon source: $menu_bar_icon_source" >&2
    exit 1
fi
install -m 644 "$menu_bar_icon_source" "$staged_app/Contents/Resources/MenuBarIcon.png"
mkdir -p "$iconset_dir"
sips -z 16 16 "$icon_source" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_source" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_dir" -o "$staged_app/Contents/Resources/NineBar.icns"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -e "$app_dir" ]]; then
    /usr/bin/swift -e '
        import Darwin

        let source = CommandLine.arguments[1]
        let destination = CommandLine.arguments[2]
        let result = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            perror("renameatx_np")
            exit(1)
        }
    ' "$staged_app" "$app_dir"
else
    mv "$staged_app" "$app_dir"
fi

echo "$app_dir"
