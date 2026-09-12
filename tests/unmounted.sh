#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "$0")/.."
work=$(mktemp -d)
device=''
cleanup() {
    if [[ -n "$device" ]]; then losetup -d "$device"; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
# A blank disposable image, exposed read-only by the kernel as an extra guard.
truncate -s 3G "$work/disk.img"
device=$(losetup --find --show --read-only "$work/disk.img")
bash storagebench.sh --read-only "$device" --profile quick --yes --output "$work/results"
reports=("$work"/results/*/results.json)
jq -e '.metadata.mode == "raw-readonly" and (.tests | length == 3) and
    all(.tests[].jobs[]; .error == 0 and .write.io_bytes == 0 and .read.io_bytes > 0)' "${reports[0]}"
echo 'Unmounted device tests passed.'
