#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cd "$project_dir"

if (( $# > 0 )); then
    set +e
    swift run NineBarCoreTests --filter "$1"
    core_status=$?
    swift run NineBarUITests --filter "$1"
    ui_status=$?
    set -e
    if [[ "$core_status" -ne 0 && "$core_status" -ne 69 ]]; then
        exit "$core_status"
    fi
    if [[ "$ui_status" -ne 0 && "$ui_status" -ne 69 ]]; then
        exit "$ui_status"
    fi
    if [[ "$core_status" -eq 69 && "$ui_status" -eq 69 ]]; then
        exit 69
    fi
else
    swift run NineBarCoreTests
    swift run NineBarUITests
    /bin/zsh "$project_dir/scripts/verify-app-bundle.sh" release
fi
