#!/bin/zsh

set -euo pipefail

product_info_plist="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
project_root="${SRCROOT:-}"

# Keep builds from exported source archives or other non-Git checkouts usable.
if [[ -z "$project_root" || ! -f "$product_info_plist" ]]; then
    exit 0
fi
if ! git -C "$project_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    exit 0
fi

last_commit_message="$(git -C "$project_root" log -1 --format=%s 2>/dev/null || true)"
day_number="$(sed -nE 's/^Day ([0-9]+):.*$/\1/p' <<< "$last_commit_message")"
if [[ -z "$day_number" ]]; then
    exit 0
fi

last_commit_date="$(git -C "$project_root" log -1 --format=%cs 2>/dev/null || true)"
current_date="$(date +%Y-%m-%d)"
if [[ -n "$last_commit_date" && "$last_commit_date" != "$current_date" ]]; then
    day_number=$((day_number + 1))
fi

day_version="day $day_number"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $day_version" "$product_info_plist"
echo "Day version: $day_version"
