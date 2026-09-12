#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
export LC_ALL=C
VERSION=2.0.0
PROFILE=standard TARGET=. DEVICE='' OUTPUT=./storagebench-results
TESTDIR='' RUN_DIR='' YES=0 INSTALL=0
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
StorageBench — Linux storage benchmarks using fio
Usage: bash storagebench.sh [options]
  --directory PATH     Filesystem to test (default: current directory)
  --read-only DEVICE   Read-only block-device tests; requires root
  --profile NAME       quick (2 GiB/10s), standard (4 GiB/30s),
                       extended (8 GiB/60s)
  --output PATH        Results parent directory (default: ./storagebench-results)
  --install-deps       Install fio and jq using apt-get (requires root)
  --yes                Skip the workload confirmation
  --help               Show help
  --version            Show version
Writes only to a unique temporary directory in filesystem mode.
Never formats, partitions, mounts, or writes directly to block devices.
EOF
}
cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -n "$TESTDIR" && -d "$TESTDIR" ]]; then
        # Only remove our single known file and empty private directory.
        rm -f -- "$TESTDIR/workload.bin" || true
        rmdir -- "$TESTDIR" || true
    fi
    if (( rc != 0 )); then
        printf 'Benchmark failed or interrupted (exit %s). Logs: %s\n' "$rc" "${RUN_DIR:-not created}" >&2
    fi
    exit "$rc"
}
value() { [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"; }
while (( $# )); do
    case "$1" in
        --directory) value "$@"; TARGET=$2; shift 2 ;;
        --read-only) value "$@"; DEVICE=$2; shift 2 ;;
        --output) value "$@"; OUTPUT=$2; shift 2 ;;
        --profile) value "$@"; PROFILE=$2; shift 2 ;;
        --yes) YES=1; shift ;;
        --install-deps) INSTALL=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --version) echo "$VERSION"; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
case "$PROFILE" in
    quick) GIB=2; RUNTIME=10 ;;
    standard) GIB=4; RUNTIME=30 ;;
    extended) GIB=8; RUNTIME=60 ;;
    *) die "Unknown profile: $PROFILE" ;;
esac
[[ $(uname -s) == Linux ]] || die 'Linux is required.'
if (( INSTALL )); then
    (( EUID == 0 )) || die '--install-deps requires root.'
    command -v apt-get >/dev/null || die 'Install fio and jq with your distribution package manager.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y fio jq
fi
for cmd in fio jq findmnt df mktemp realpath; do
    command -v "$cmd" >/dev/null || die "Missing $cmd. On Debian/Ubuntu: sudo apt-get install fio jq util-linux coreutils"
done
[[ $(fio --version) == fio-* ]] || die 'fio must be the Flexible I/O Tester, not the Fiona CLI.'
SIZE=$((GIB * 1024 * 1024 * 1024))
MODE=filesystem
if [[ -n "$DEVICE" ]]; then
    MODE=raw-readonly
    (( EUID == 0 )) || die 'Block-device reads require root.'
    DEVICE=$(realpath -e -- "$DEVICE")
    [[ -b "$DEVICE" ]] || die 'Read-only target must be a block device.'
    [[ "$DEVICE" != *:* && "$DEVICE" != *$'\n'* && "$DEVICE" != *\\* ]] || die 'Unsupported characters in device path.'
    (( $(blockdev --getsize64 "$DEVICE") >= SIZE )) || die 'Device is smaller than the profile test region.'
    FILE=$DEVICE
else
    TARGET=$(realpath -e -- "$TARGET")
    [[ -d "$TARGET" && -w "$TARGET" ]] || die 'Target must be an existing writable directory.'
    # fio uses colons as filename separators, even inside quoted arguments.
    [[ "$TARGET" != *:* && "$TARGET" != *$'\n'* && "$TARGET" != *\\* ]] || die 'Target paths cannot contain colons, backslashes or newlines.'
    AVAILABLE=$(df -B1 --output=avail -- "$TARGET" | tail -n 1)
    (( AVAILABLE >= SIZE + 1073741824 )) || die "Need at least $((GIB + 1)) GiB free."
fi
printf '\nStorageBench %s | %s | %s\n' "$VERSION" "$MODE" "$PROFILE"
printf 'Target: %s\nTest region: %s GiB | each timed test: %ss\n' "${DEVICE:-$TARGET}" "$GIB" "$RUNTIME"
if [[ "$MODE" == filesystem ]]; then
    findmnt -T "$TARGET" -o SOURCE,TARGET,FSTYPE
    echo 'This performs sustained writes in a temporary file and can affect other workloads.'
else
    echo 'Device I/O is read-only. Result files are still written to the output directory.'
fi
if (( ! YES )); then
    [[ -t 0 ]] || die 'Non-interactive execution requires --yes.'
    read -r -p 'Run benchmark? [y/N] ' answer
    [[ "$answer" == y || "$answer" == Y ]] || exit 0
fi
umask 077
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p -- "$OUTPUT"
OUTPUT=$(realpath -e -- "$OUTPUT")
RUN_DIR=$(mktemp -d "$OUTPUT/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
if [[ "$MODE" == filesystem ]]; then
    TESTDIR=$(mktemp -d "$TARGET/.storagebench-XXXXXXXX")
    FILE=$TESTDIR/workload.bin
fi
jq -n --arg version "$VERSION" --arg profile "$PROFILE" --arg mode "$MODE" \
    --arg target "${DEVICE:-$TARGET}" --arg kernel "$(uname -sr)" \
    --arg fio "$(fio --version)" --arg date "$(date -u +%FT%TZ)" \
    --argjson bytes "$SIZE" --argjson runtime "$RUNTIME" \
    '{version:$version,profile:$profile,mode:$mode,target:$target,kernel:$kernel,fio:$fio,date:$date,size_bytes:$bytes,runtime_seconds:$runtime}' > "$RUN_DIR/metadata.json"
printf 'TEST\tDIRECTION\tMiB/s\tIOPS\tMEAN_COMPLETION_US\tMEAN_FSYNC_US\n' > "$RUN_DIR/summary.tsv"
run_fio() {
    local name=$1 rw=$2 bs=$3 depth=$4 jobs=$5
    shift 5
    local guard=()
    [[ "$MODE" != raw-readonly ]] || guard=(--readonly --allow_file_create=0)
    printf '\nRunning %s ...\n' "$name"
    fio --name="$name" --filename="$FILE" --size="$SIZE" \
        --rw="$rw" --bs="$bs" --ioengine=libaio --direct=1 \
        --iodepth="$depth" --numjobs="$jobs" --group_reporting=1 \
        --refill_buffers=1 --randrepeat=0 --eta=never \
        --output-format=json --output="$RUN_DIR/$name.json" \
        "${guard[@]}" "$@" 2>&1 | tee "$RUN_DIR/$name.log"
    jq -e '.jobs | length > 0 and all(.[]; .error == 0)' "$RUN_DIR/$name.json" >/dev/null || die "fio reported errors in $name"
    jq -r --arg name "$name" '
        .jobs[] | . as $job | ["read", "write"][] as $direction |
        $job[$direction] | select(.io_bytes > 0) |
        [$name, $direction, (.bw_bytes / 1048576), .iops,
         (.clat_ns.mean / 1000), (($job.sync.lat_ns.mean // 0) / 1000)] | @tsv
    ' "$RUN_DIR/$name.json" | tee -a "$RUN_DIR/summary.tsv"
}
if [[ "$MODE" == filesystem ]]; then
    # Fully initialize the same file before reads; avoid sparse/unwritten extents.
    run_fio seq-write write 1M 32 1 --end_fsync=1
fi
run_fio seq-read read 1M 32 1
TIMED=(--runtime="$RUNTIME" --time_based=1)
run_fio rand-read-qd1 randread 4k 1 1 "${TIMED[@]}"
run_fio rand-read-qd32x4 randread 4k 32 4 "${TIMED[@]}"
if [[ "$MODE" == filesystem ]]; then
    run_fio rand-write-qd1 randwrite 4k 1 1 "${TIMED[@]}" --end_fsync=1
    run_fio rand-write-qd32x4 randwrite 4k 32 4 "${TIMED[@]}" --end_fsync=1
    run_fio mixed-70r30w randrw 4k 32 4 "${TIMED[@]}" --rwmixread=70 --end_fsync=1
    run_fio fsync-write write 4k 1 1 "${TIMED[@]}" --ioengine=sync --direct=0 --fsync=1
fi
jq -s '{metadata:.[0],tests:.[1:]}' "$RUN_DIR/metadata.json" "$RUN_DIR"/seq-*.json "$RUN_DIR"/rand-*.json \
    > "$RUN_DIR/read-write-results.json"
# Include mixed and fsync results where present, without unmatched glob arguments.
if [[ "$MODE" == filesystem ]]; then
    jq --slurpfile mixed "$RUN_DIR/mixed-70r30w.json" --slurpfile fsync "$RUN_DIR/fsync-write.json" \
        '.tests += $mixed + $fsync' "$RUN_DIR/read-write-results.json" > "$RUN_DIR/results.json"
else
    cp -- "$RUN_DIR/read-write-results.json" "$RUN_DIR/results.json"
fi
rm -- "$RUN_DIR/read-write-results.json"
printf '\nCompleted. Results: %s\n\n' "$RUN_DIR"
if command -v column >/dev/null; then
    column -t -s $'\t' "$RUN_DIR/summary.tsv"
else
    cat "$RUN_DIR/summary.tsv"
fi
