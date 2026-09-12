#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "$0")/.."
bash -n storagebench.sh
[[ $(bash storagebench.sh --version) == 2.0.0 ]]
bash storagebench.sh --help | grep -q 'Usage:'
for args in '--unknown' '--profile invalid' '--directory' '--output' '--read-only'; do
    # Intentionally split the fixed test cases into CLI arguments.
    # shellcheck disable=SC2086
    if bash storagebench.sh $args >/dev/null 2>&1; then
        echo "Expected rejection: $args" >&2
        exit 1
    fi
done
echo 'CLI tests passed.'
