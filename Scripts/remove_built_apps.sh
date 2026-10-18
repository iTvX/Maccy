#!/bin/bash
# The runner is also a Mac where Maccy is used day to day. Every app bundle a build
# leaves behind gets registered with LaunchServices and indexed by Spotlight, so it
# shows up next to the installed Maccy and can be launched instead of it. Remove the
# bundles once they aren't needed, unregistering them first so no stale entry stays.
set -uo pipefail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' app; do
        "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
        rm -rf "$app"
        echo "Removed $app"
    done < <(find "$dir" -name '*.app' -type d -prune -print0)
done
