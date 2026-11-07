#!/bin/zsh
# Measures Kite against its limits (docs/EDITOR-SPEC.md). Exits non-zero if any is broken.
#   scripts/budget.sh            builds release first
#   scripts/budget.sh --no-build use the existing build/Kite.app
set -uo pipefail
cd "$(dirname "$0")/.."
export KITE_NO_SESSION=1   # measure a clean launch, and leave your saved session alone
[[ "${1:-}" == "--no-build" ]] || scripts/bundle.sh >/dev/null || exit 1
APP=build/Kite.app
BIN=$APP/Contents/MacOS/Kite
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; pkill -f "$PWD/$BIN" 2>/dev/null' EXIT
failed=0

report() {   # name, value, unit, limit, comparison ("<" means value must be below limit)
    local verdict=pass
    if (( $(echo "$2 >= $4" | bc -l) )); then verdict=FAIL; failed=1; fi
    printf "%-34s %8s %-4s limit %6s %-4s %s\n" "$1" "$2" "$3" "$4" "$3" "$verdict"
}

# App size.
size_mb=$(du -sk "$APP" | awk '{printf "%.1f", $1/1024}')
report "app size" "$size_mb" MB 20

# Launch to typing: median of 5 cold-ish starts, opening a file.
SAMPLE=Sources/Kite/EditorView.swift
times=()
for i in 1 2 3 4 5; do
    t=$(KITE_LAUNCH_PROBE=1 perl -e 'alarm 10; exec @ARGV' "$BIN" "$PWD/$SAMPLE" 2>/dev/null </dev/null | awk '/launch_ms/ {print $2}')
    times+=(${t:-99999})
done
launch=$(printf "%s\n" "${times[@]}" | sort -n | sed -n 3p)
report "launch to typing (median of 5)" "$launch" ms 150

# Memory with a mid-size project open (Kite's own folder and a large file).
"$BIN" "$PWD" "$PWD/$SAMPLE" >/dev/null 2>&1 </dev/null &
pid=$!
sleep 4
mem=$(footprint $pid 2>/dev/null | awk '/Footprint:/ {for (i=1;i<=NF;i++) if ($i=="Footprint:") {v=$(i+1); u=$(i+2)}} END {if (u=="GB") v*=1024; print v}')
kill $pid 2>/dev/null; wait $pid 2>/dev/null
report "memory, project open" "${mem:-0}" MB 100

# Typing and scrolling on a 5 MB file.
python3 - "$TMP/big.swift" <<'PY'
import sys
src = open("Sources/Kite/EditorView.swift").read()
with open(sys.argv[1], "w") as f:
    n = 0
    while n < 5_000_000:
        f.write(src); n += len(src)
PY
bench=$(perl -e 'alarm 120; exec @ARGV' "$BIN" --bench "$TMP/big.swift" 2>/dev/null)
worst=$(echo "$bench" | awk '/worst single keystroke/ {print $4}')
scroll_total=$(echo "$bench" | awk '/scroll through 50 screens/ {print $(NF-1)}')
scroll=$(echo "$scroll_total / 50" | bc -l | xargs printf "%.2f")
report "worst keystroke, 5 MB file" "$worst" ms 8
report "scroll, per screen (120 fps = 8.3)" "$scroll" ms 8.3

exit $failed
