#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
#
# The programs in this folder in Flux, Lua and Python: each run a few times,
# the three taking turns so a busy moment hits all of them alike, and the
# best time of each kept. Build Flux first with
# `zig build -Doptimize=ReleaseFast`.
#
#     bench/compare.sh [runs]
#
# FLUX, LUA and PYTHON name the programs when they are not
# zig-out/bin/flux, lua and python3. It needs a `date` that knows %N:
# Linux's, or Git Bash's on Windows.

set -eu
cd "$(dirname "$0")"
FLUX=${FLUX:-../zig-out/bin/flux}
LUA=${LUA:-lua}
PYTHON=${PYTHON:-python3}
RUNS=${1:-3}

ms() {
    local start end
    start=$(date +%s%N)
    "$@" > /dev/null
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}

printf "%-10s %9s %9s %9s\n" "" flux lua python
for b in fib loop nbody trees strings particles; do
    best_flux=999999; best_lua=999999; best_python=999999
    for _ in $(seq "$RUNS"); do
        t=$(ms "$FLUX" run "$b.flux"); [ "$t" -lt "$best_flux" ] && best_flux=$t
        t=$(ms "$LUA" "$b.lua"); [ "$t" -lt "$best_lua" ] && best_lua=$t
        t=$(ms "$PYTHON" "$b.py"); [ "$t" -lt "$best_python" ] && best_python=$t
    done
    printf "%-10s %6d ms %6d ms %6d ms\n" "$b" "$best_flux" "$best_lua" "$best_python"
done
