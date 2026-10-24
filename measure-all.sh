#!/bin/bash
# Usage: ./measure-all.sh [runs per case, default 2]
# Runs measure.sh for every mode (and a few flag variations) and prints a table.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
runs="${1:-2}"

cases=(
    "never-open" "no-content" "plain" "appkit-glass" "swiftui-glass"
    "appkit-glass-clear" "appkit-glass-container" "swiftui-glass-container"
    "popover-glass" "popover-plain" "popover-teardown" "visual-effect" "control-timer"
    "popover-glass --twice" "popover-teardown --twice"
    "appkit-glass --twice" "appkit-glass --click" "appkit-glass --activate"
    "appkit-glass --borderless" "appkit-glass --below-item"
    "appkit-glass --under-mouse" "swiftui-glass --borderless --below-item"
)

rows=()
for c in "${cases[@]}"; do
    line=$(printf '%-40s' "$c")
    for _ in $(seq 1 "$runs"); do
        # shellcheck disable=SC2086 # the case string is mode plus flags
        out=$("$here/measure.sh" $c 2>/dev/null)
        echo "$out"
        verdict=$(sed -n 's/^verdict: //p' <<<"$out")
        line+=$(printf ' | %-30s' "${verdict:-error}")
    done
    echo "$line"; echo
    rows+=("$line")
done

echo
printf '%-40s' "case"; for i in $(seq 1 "$runs"); do printf ' | %-30s' "run $i"; done; echo
printf '%s\n' "${rows[@]}"
