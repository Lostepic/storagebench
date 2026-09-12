#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail
export LC_ALL=C
VERSION=2.2.0
PROFILE=standard TARGET=. DEVICE='' OUTPUT=./storagebench-results
TESTDIR='' RUN_DIR='' YES=0 INSTALL=0
TARGET_SET=0 DEVICE_SET=0 PROMPT_OPEN=0
REPORT='' COLOR=1 C_ACCENT='' C_BOLD='' C_RESET=''
STEP=0 TOTAL_STEPS=0
init_style() {
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR+x} ]] && (( COLOR )); then
        C_ACCENT=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
    fi
}
rule() { printf '  %s\n' '----------------------------------------------------------------------------'; }
section() { printf '\n  %s%s%s\n' "$C_ACCENT$C_BOLD" "$*" "$C_RESET"; }
banner() {
    section "STORAGEBENCH  /  v$VERSION"
    printf '  Linux storage performance · fio\n'
    rule
}
table_header() {
    printf '  %-22s %-5s %12s %9s %10s %10s\n' 'WORKLOAD' 'I/O' 'THROUGHPUT' 'IOPS' 'LATENCY' 'FSYNC'
    rule
}
format_rows() {
    # TSV is deliberately left at full precision; only the presentation is rounded.
    awk -F '\t' '
    function bandwidth(mib) {
        if (mib >= 1048576) return sprintf("%.2f TiB/s", mib / 1048576)
        if (mib >= 1024) return sprintf("%.2f GiB/s", mib / 1024)
        if (mib >= 1) return sprintf("%.2f MiB/s", mib)
        if (mib >= 1 / 1024) return sprintf("%.2f KiB/s", mib * 1024)
        return sprintf("%.2f B/s", mib * 1048576)
    }
    function iops(n) {
        if (n >= 1000000) return sprintf("%.2fM", n / 1000000)
        if (n >= 1000) return sprintf("%.2fk", n / 1000)
        return sprintf("%.0f", n)
    }
    function latency(us) {
        if (us >= 1000000) return sprintf("%.2f s", us / 1000000)
        if (us >= 1000) return sprintf("%.2f ms", us / 1000)
        if (us >= 1 || us == 0) return sprintf("%.2f us", us)
        return sprintf("%.2f ns", us * 1000)
    }
    BEGIN {
        label["seq-write"]="Sequential 1M QD32"
        label["seq-read"]="Sequential 1M QD32"
        label["rand-read-qd1"]="Random 4K QD1"
        label["rand-write-qd1"]="Random 4K QD1"
        label["rand-read-qd32x4"]="Random 4K QD32 x4"
        label["rand-write-qd32x4"]="Random 4K QD32 x4"
        label["mixed-70r30w"]="Mixed 4K 70R/30W"
        label["fsync-write"]="Sync write 4K QD1"
    }
    $1 == "TEST" { next }
    NF == 6 {
        name=($1 in label ? label[$1] : $1)
        sync=($1 == "fsync-write" ? latency($6) : "-")
        printf "  %-22s %-5s %12s %9s %10s %10s\n", name, $2, bandwidth($3), iops($4), latency($5), sync
    }'
}
render_summary() {
    table_header
    format_rows < "$1"
    rule
    printf '  Throughput: bytes/second (MiB = 1024 KiB; GiB = 1024 MiB).\n'
    printf '  IOPS: operations/second; k = 1,000, M = 1,000,000.\n'
    printf '  Latency: mean I/O completion; fsync: mean sync-call time.\n'
    printf '  us = microseconds; ms = milliseconds; - = not applicable.\n'
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
StorageBench — Linux storage benchmarks using fio
Usage: bash storagebench.sh [options]
  --directory PATH     Filesystem to test (otherwise opens a target picker)
  --read-only DEVICE   Read-only block-device tests; requires root
  --profile NAME       quick (2 GiB/10s), standard (4 GiB/30s),
                       extended (8 GiB/60s)
  --output PATH        Results parent directory (default: ./storagebench-results)
  --install-deps       Install fio and jq using apt-get (requires root)
  --show-results PATH  Display a saved results directory without running tests
  --no-color           Disable terminal colours (also respects NO_COLOR)
  --yes                Skip the workload confirmation
  --help               Show help
  --version            Show version
Writes only to a unique temporary directory in filesystem mode.
Never formats, partitions, mounts, or writes directly to block devices.
EOF
}
prompt() {
    if (( ! PROMPT_OPEN )); then
        if { exec 3<>/dev/tty; } 2>/dev/null; then
            PROMPT_OPEN=1
        else
            die 'No terminal available. Specify --directory PATH or --read-only DEVICE together with --yes.'
        fi
    fi
    printf '%s' "$1" >&3
    IFS= read -r -u 3 ANSWER || die 'Input ended before a selection was made.'
}
pick_target() {
    local data row path source fs opts size type n i
    local -a targets=("$PWD" /) modes=(filesystem filesystem) labels=("Current directory: $PWD" 'OS/root filesystem: / (temporary-file read/write tests)')
    data=$(findmnt --json --list --output TARGET,SOURCE,FSTYPE,OPTIONS) || die 'Unable to list mounted filesystems.'
    while IFS= read -r row; do
        path=$(jq -r '.target' <<< "$row")
        source=$(jq -r '.source' <<< "$row")
        fs=$(jq -r '.fstype' <<< "$row")
        opts=$(jq -r '.options' <<< "$row")
        [[ "$path" != / && "$source" == /dev/* && ",$opts," == *,rw,* ]] || continue
        targets+=("$path"); modes+=(filesystem)
        labels+=("Mounted: $path [$source, $fs] — temporary-file read/write tests")
    done < <(jq -c '.filesystems[]' <<< "$data")
    data=$(lsblk --json --bytes --paths --output NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS) || die 'Unable to list block devices.'
    while IFS= read -r row; do
        path=$(jq -r '.name' <<< "$row")
        type=$(jq -r '.type' <<< "$row")
        size=$(jq -r '.size' <<< "$row")
        fs=$(jq -r '.fstype // "no filesystem detected"' <<< "$row")
        targets+=("$path"); modes+=(raw-readonly)
        labels+=("Device: $path [$type, $(numfmt --to=iec "$size"), $fs] — READ ONLY (mounted or unmounted)")
    done < <(jq -c '[.blockdevices[] | recurse(.children[]?) | select(.type != "rom")] | unique_by(.name)[]' <<< "$data")
    section 'Where should StorageBench run?'
    printf '\n'
    for i in "${!targets[@]}"; do printf '  %s) %s\n' "$((i + 1))" "${labels[$i]}"; done
    printf '\n  c) Enter a directory manually\n  q) Quit\n\n'
    echo 'OS and mounted filesystem tests write only a temporary file.'
    echo 'Unmounted/blank disks can be tested read-only without mounting or formatting.'
    echo 'For write tests on an unmounted filesystem, mount it yourself, then choose its directory.'
    while :; do
        prompt 'Select target [1]: '
        case "$ANSWER" in
            q|Q) exit 0 ;;
            c|C)
                prompt 'Existing directory path: '
                TARGET=$ANSWER
                return ;;
            '') ANSWER=1 ;;
        esac
        if [[ "$ANSWER" =~ ^[0-9]{1,6}$ ]]; then
            n=$((10#$ANSWER))
            if (( n >= 1 && n <= ${#targets[@]} )); then
                if [[ "${modes[$((n - 1))]}" == filesystem ]]; then
                    TARGET=${targets[$((n - 1))]}
                else
                    DEVICE=${targets[$((n - 1))]}
                fi
                return
            fi
        fi
        echo 'Choose a listed number, c, or q.'
    done
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
        --directory) value "$@"; TARGET=$2; TARGET_SET=1; shift 2 ;;
        --read-only) value "$@"; DEVICE=$2; DEVICE_SET=1; shift 2 ;;
        --output) value "$@"; OUTPUT=$2; shift 2 ;;
        --profile) value "$@"; PROFILE=$2; shift 2 ;;
        --yes) YES=1; shift ;;
        --install-deps) INSTALL=1; shift ;;
        --show-results) value "$@"; REPORT=$2; shift 2 ;;
        --no-color) COLOR=0; shift ;;
        --help|-h) usage; exit 0 ;;
        --version) echo "$VERSION"; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done
init_style
if [[ -n "$REPORT" ]]; then
    [[ -f "$REPORT/summary.tsv" ]] || die "No summary.tsv found in $REPORT"
    banner
    section 'SAVED RESULTS'
    render_summary "$REPORT/summary.tsv"
    printf '\n  Results: %s\n' "$REPORT"
    exit 0
fi
(( ! TARGET_SET || ! DEVICE_SET )) || die 'Choose either --directory or --read-only, not both.'
(( ! YES || TARGET_SET || DEVICE_SET )) || die '--yes requires an explicit --directory or --read-only target.'
case "$PROFILE" in
    quick) GIB=2; RUNTIME=10 ;;
    standard) GIB=4; RUNTIME=30 ;;
    extended) GIB=8; RUNTIME=60 ;;
    *) die "Unknown profile: $PROFILE" ;;
esac
[[ $(uname -s) == Linux ]] || die 'Linux is required.'
banner
if (( INSTALL )); then
    (( EUID == 0 )) || die '--install-deps requires root.'
    command -v apt-get >/dev/null || die 'Install fio and jq with your distribution package manager.'
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y fio jq
fi
for cmd in fio jq findmnt lsblk numfmt blockdev df mktemp realpath awk; do
    command -v "$cmd" >/dev/null || die "Missing $cmd. On Debian/Ubuntu: sudo apt-get install fio jq util-linux coreutils"
done
[[ $(fio --version) == fio-* ]] || die 'fio must be the Flexible I/O Tester, not the Fiona CLI.'
if (( ! TARGET_SET && ! DEVICE_SET )); then pick_target; fi
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
section 'BENCHMARK SETUP'
printf '  %-14s %s\n' 'Target' "${DEVICE:-$TARGET}" 'Mode' "$MODE" 'Profile' "$PROFILE"
printf '  %-14s %s GiB  /  %ss per timed workload\n' 'Test region' "$GIB" "$RUNTIME"
if [[ "$MODE" == filesystem ]]; then
    findmnt -T "$TARGET" -o SOURCE,TARGET,FSTYPE
    echo 'This performs sustained writes in a temporary file and can affect other workloads.'
else
    echo 'Device I/O is read-only. Result files are still written to the output directory.'
fi
if (( ! YES )); then
    prompt 'Run benchmark? [y/N] '
    [[ "$ANSWER" == y || "$ANSWER" == Y ]] || exit 0
fi
umask 077
START_SECONDS=$SECONDS
TOTAL_STEPS=8
[[ "$MODE" != raw-readonly ]] || TOTAL_STEPS=3
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
    STEP=$((STEP + 1))
    section "[$STEP/$TOTAL_STEPS] $name"
    if [[ "$name" == seq-* ]]; then
        printf '  Running one pass over %s GiB ...\n' "$GIB"
    else
        printf '  Running %ss workload ...\n' "$RUNTIME"
    fi
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
    ' "$RUN_DIR/$name.json" > "$RUN_DIR/$name.tsv"
    cat "$RUN_DIR/$name.tsv" >> "$RUN_DIR/summary.tsv"
    table_header
    format_rows < "$RUN_DIR/$name.tsv"
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
section 'BENCHMARK COMPLETE'
ELAPSED=$((SECONDS - START_SECONDS))
printf '  %s workloads finished in %sm %02ss\n\n' "$TOTAL_STEPS" "$((ELAPSED / 60))" "$((ELAPSED % 60))"
render_summary "$RUN_DIR/summary.tsv" | tee "$RUN_DIR/summary.txt"
printf '\n  Results saved to: %s\n' "$RUN_DIR"
printf '  summary.txt  /  summary.tsv  /  results.json\n\n'
