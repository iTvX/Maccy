#!/bin/bash
# The runner is also a Mac where Maccy is used day to day. Every app bundle a build
# leaves behind gets registered with LaunchServices and indexed by Spotlight, so it
# shows up next to the installed Maccy and can be launched instead of it. Remove the
# bundles once they aren't needed, unregistering them first so no stale entry stays.
# Apps nested inside a bundle (Sparkle's Updater.app) are registered on their own,
# so unregister those too.
set -uo pipefail
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' app; do
        while IFS= read -r -d '' bundle; do
            "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
        done < <(find "$app" -name '*.app' -type d -print0)
        rm -rf "$app"
        echo "Removed $app"
    done < <(find "$dir" -name '*.app' -type d -prune -print0)
done
