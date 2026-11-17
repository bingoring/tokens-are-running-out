#!/bin/sh
# Runs the Swift report and the prototype on the synthetic fixtures and fails on any difference.
# No real transcripts are involved. Usage: prototype/parity.sh
set -eu
cd "$(dirname "$0")/.."
fixtures=Tests/RunningOutCoreTests/Fixtures/parity
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The fixtures end in .jsonl.txt so that transcript files are never committed; restore the names.
(cd "$fixtures" && find projects -name '*.jsonl.txt') | while read -r file; do
    mkdir -p "$work/$(dirname "$file")"
    cp "$fixtures/$file" "$work/${file%.txt}"
done

window="--from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z"
swift build --product running-out >/dev/null
# shellcheck disable=SC2086
.build/debug/running-out report --root "$work/projects" --db "$work/index.sqlite" $window >"$work/swift.txt"
# shellcheck disable=SC2086
python3 -I prototype/drain.py --root "$work/projects" $window >"$work/prototype.txt"

diff -u "$work/prototype.txt" "$work/swift.txt"
diff -u "$fixtures/expected-report.txt" "$work/swift.txt"
echo "parity: the Swift report and the prototype agree on the fixtures"
