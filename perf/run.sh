#!/bin/zsh
# Builds the EnergyBench tool and runs it against the running WheelClick.
#
#   perf/run.sh [all|idle|touchstorm|dragstorm|scrollcontrol|latency]
#   perf/run.sh request-permissions   # one-time synthetic-event grant
#   perf/run.sh --fresh [...]         # rebuild Release and relaunch the app first
#
# `idle` works with no permissions; the storm and latency scenarios need the
# terminal to hold the Accessibility grant (see request-permissions).
set -euo pipefail
cd "$(dirname "$0")/.."
source perf/lib.sh

if [[ "${1:-}" == "--fresh" ]]; then
    shift
    rebuild_and_relaunch
fi

BENCH="$BUILD/energybench"
if [[ ! -x "$BENCH" || perf/EnergyBench/main.swift -nt "$BENCH" ]]; then
    swiftc -O perf/EnergyBench/main.swift -o "$BENCH"
    sign_bench "$BENCH" energybench
fi

exec "$BENCH" "${1:-all}"
