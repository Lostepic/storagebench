#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '%s\n' \
    $'TEST\tDIRECTION\tMiB/s\tIOPS\tMEAN_COMPLETION_US\tMEAN_FSYNC_US' \
    $'seq-write\twrite\t1600\t1600\t19123.580691894\t0' \
    $'seq-read\tread\t2786.3945569992065\t2786.394558\t11254.908716797\t0' \
    $'rand-read-qd32x4\tread\t492.7854862213135\t126153.084692\t996.125242191\t0' \
    $'fsync-write\twrite\t0.9717769622802734\t248.775122\t43.542799437\t3963.22932074' \
    $'boundary\tread\t1024\t1000000\t1000000\t0' \
    $'small\tread\t0.00000095367431640625\t0\t0.5\t0' \
    > "$work/summary.tsv"
cp "$work/summary.tsv" "$work/original.tsv"
bash storagebench.sh --show-results "$work" --no-color > "$work/display.txt"
for expected in '1.56 GiB/s' '2.72 GiB/s' '492.79 MiB/s' '126.15k' '3.96 ms' '995.10 KiB/s' '19.12 ms' '1.00 GiB/s' '1.00M' '1.00 s' '1.00 B/s' '500.00 ns'; do
    grep -Fq "$expected" "$work/display.txt" || { echo "Missing formatted value: $expected" >&2; exit 1; }
done
if grep -q $'\033' "$work/display.txt"; then echo 'Unexpected ANSI escapes' >&2; exit 1; fi
cmp "$work/summary.tsv" "$work/original.tsv"
cat "$work/display.txt"
echo 'Display and precision-preservation tests passed.'
