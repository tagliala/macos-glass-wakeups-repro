#!/bin/bash
# Usage: ./measure.sh <mode> [extra app flags, e.g. --twice --click]
# Launches ./glass-wakeups --mode <mode> --auto, waits until the panel has
# been closed plus 5 s, records a System Trace of the process (20 s, or
# TRACE_SECONDS) and prints the wake times, the intervals and a verdict
# (periodic, quiet or irregular).
set -euo pipefail

mode="${1:?usage: measure.sh <mode> [flags]}"
shift
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/glass-wakeups"
[ -x "$bin" ] || { echo "build first: swiftc -O main.swift -o glass-wakeups" >&2; exit 1; }

dir="$(mktemp -d)"
log="$dir/app.log"
pid=""

cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    case "$dir" in
        /tmp/?*|/private/tmp/?*|"${TMPDIR%/}"/?*) rm -rf -- "$dir" ;;
        *) echo "not removing unexpected temp dir: $dir" >&2 ;;
    esac
}
trap cleanup EXIT

"$bin" --mode "$mode" --auto "$@" >"$log" 2>&1 &
pid=$!

# Wait for the app to report that it is done with the panel (max 60 s).
for _ in $(seq 1 600); do
    grep -q '^done' "$log" && break
    kill -0 "$pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
    sleep 0.1
done
grep -q '^done' "$log" || { echo "app never printed 'done'" >&2; cat "$log" >&2; exit 1; }
sleep 5

trace="$dir/run.trace"
xcrun xctrace record --template 'System Trace' --attach "$pid" \
    --time-limit "${TRACE_SECONDS:-20}s" --output "$trace" >/dev/null 2>&1
xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run/data/table[@schema="thread-state"]' >"$dir/ts.xml" 2>/dev/null

echo "mode: $mode $*"
grep -v '^pid ' "$log" | sed 's/^/app: /'

python3 -I - "$dir/ts.xml" "$pid" <<'PY'
import re, sys

xml = open(sys.argv[1], encoding="utf-8").read()
pid = sys.argv[2]

# Repeated values are written once with id="N" fmt="..." and later as ref="N".
fmt = {m.group(2): m.group(3) for m in re.finditer(r'<([\w-]+) id="(\d+)" fmt="([^"]*)"', xml)}
raw = {m.group(1): m.group(2) for m in re.finditer(r'<start-time id="(\d+)"[^>]*>(\d+)<', xml)}

def value(row, tag, use_raw=False):
    m = re.search(r'<%s (?:id="(\d+)"[^>]*|ref="(\d+)")' % tag, row)
    if not m:
        return None
    key = m.group(1) or m.group(2)
    return raw.get(key) if use_raw else fmt.get(key)

starts = []
for row in re.findall(r"<row>(.*?)</row>", xml, re.S):
    if value(row, "thread-state") != "Running":
        continue
    proc = value(row, "process") or ""
    if f"({pid})" not in proc:
        continue
    t = value(row, "start-time", use_raw=True)
    if t is not None:
        starts.append(int(t) / 1e9)

starts.sort()
wakes = []
for t in starts:
    if not wakes or t - wakes[-1][-1] > 0.050:
        wakes.append([t])
    else:
        wakes[-1].append(t)
times = [w[0] for w in wakes]
gaps = [b - a for a, b in zip(times, times[1:])]

print("running intervals:", len(starts), " wakes:", len(times))
print("wake times (s):", " ".join(f"{t:.3f}" for t in times) or "-")
print("intervals  (s):", " ".join(f"{g:.3f}" for g in gaps) or "-")
# Periodic: a chain of at least 4 wakes, each 0.85-1.15 P after the previous
# one, for some P taken from the intervals (>= 1 s). Unrelated extra wakes in
# between do not break the chain, and the timer's own leeway (beats a few
# hundred ms early or late) is tolerated.
def chain(p):
    best = []
    for start in times:
        c = [start]
        while True:
            nxt = [u for u in times if 0.85 * p <= u - c[-1] <= 1.15 * p]
            if not nxt:
                break
            c.append(min(nxt, key=lambda u: abs(u - c[-1] - p)))
        best = max(best, c, key=len)
    return best

c = max((chain(g) for g in gaps if g >= 1.0), key=len, default=[])
if len(c) >= 4:
    steps = sorted(b - a for a, b in zip(c, c[1:]))
    print(f"verdict: periodic ~{steps[len(steps) // 2]:.1f}s ({len(c)} of {len(times)} wakes)")
# Attaching and stopping the trace each wake the process once.
elif len(times) <= 2:
    print("verdict: quiet")
else:
    print(f"verdict: irregular ({len(times)} wakes)")
PY
