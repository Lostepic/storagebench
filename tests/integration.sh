#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "$0")/.."
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/target with spaces"
bash storagebench.sh --directory "$work/target with spaces" --output "$work/results" --profile quick --yes
report=("$work"/results/*/results.json)
jq -e '.metadata.mode == "filesystem" and (.tests | length == 8) and all(.tests[].jobs[]; .error == 0)' "${report[0]}"
[[ -z $(find "$work/target with spaces" -mindepth 1 -print -quit) ]]
# Fail the first fio workload and check that cleanup still happens.
mkdir "$work/bin"
cat > "$work/bin/fio" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo fio-3.38; exit 0; fi
exit 42
EOF
chmod +x "$work/bin/fio"
if PATH="$work/bin:$PATH" bash storagebench.sh --directory "$work/target with spaces" --output "$work/failure" --profile quick --yes; then
    echo 'Expected fio failure' >&2
    exit 1
fi
[[ -z $(find "$work/target with spaces" -mindepth 1 -print -quit) ]]
cat > "$work/bin/fio" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo fio-3.38; exit 0; fi
# fio is launched from a pipeline; PPID is the benchmark shell.
kill -TERM "$PPID"
exit 0
EOF
rc=0
PATH="$work/bin:$PATH" bash storagebench.sh --directory "$work/target with spaces" --output "$work/terminated" --profile quick --yes || rc=$?
[[ "$rc" == 143 ]]
[[ -z $(find "$work/target with spaces" -mindepth 1 -print -quit) ]]
echo 'Integration tests passed.'
